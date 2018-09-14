{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE Safe #-}
-------------------------------------------------------------------------------
-- |
-- Module      :  BroadcastChan.Extra
-- Copyright   :  (C) 2014-2018 Merijn Verstraaten
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Merijn Verstraaten <merijn@inconsistent.nl>
-- Stability   :  experimental
-- Portability :  haha
--
-- Functions in this module are *NOT* intended to be used by regular users of
-- the library. Rather, they are intended for implementing parallel processing
-- libraries on top of @broadcast-chan@, such as @broadcast-chan-conduit@.
--
-- This module, while not for end users, is considered part of the public API,
-- so users can rely on PVP bounds to avoid breakage due to changes to this
-- module.
-------------------------------------------------------------------------------
module BroadcastChan.Extra
    ( Action(..)
    , BracketOnError(..)
    , Handler(..)
    , mapHandler
    , runParallel
    , runParallel_
    ) where

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative ((<*))
#endif
import Control.Concurrent
    (ThreadId, forkFinally, killThread, mkWeakThreadId, myThreadId)
import Control.Concurrent.MVar
import Control.Concurrent.QSem
import Control.Concurrent.QSemN
import Control.Exception
    (Exception(..), SomeException(..), catch, mask_, throwIO, throwTo)
import Control.Monad ((>=>), replicateM, void)
import Control.Monad.IO.Class (MonadIO(..))
import Data.Typeable (Typeable)
import System.Mem.Weak (Weak, deRefWeak)

import BroadcastChan.Internal

-- DANGER! Breaks the invariant that you can't write to closed channels!
-- Only meant to be used in 'parallelCore'!
unsafeWriteBChan :: MonadIO m => BroadcastChan In a -> a -> m ()
unsafeWriteBChan (BChan writeVar) val = liftIO $ do
  new_hole <- newEmptyMVar
  mask_ $ do
    old_hole <- takeMVar writeVar
    -- old_hole is only full if the channel was previously closed
    item <- tryTakeMVar old_hole
    case item of
        Nothing -> return ()
        Just Closed -> putMVar new_hole Closed
        Just _ -> error "unsafeWriteBChan hit an impossible condition!"
    putMVar old_hole (ChItem val new_hole)
    putMVar writeVar new_hole
{-# INLINE unsafeWriteBChan #-}

data Shutdown = Shutdown deriving (Show, Typeable)
instance Exception Shutdown

-- | Action to take when an exception occurs while processing an element.
data Action
    = Drop
    -- ^ Drop the current element and continue processing.
    | Retry
    -- ^ Retry by appending the current element to the queue of remaining
    --   elements.
    | Terminate
    -- ^ Stop all processing and reraise the exception.
    deriving (Eq, Show)

-- | Exception handler for parallel processing.
data Handler m a
    = Simple Action
    -- ^ Always take the specified 'Action'.
    | Handle (a -> SomeException -> m Action)
    -- ^ Allow inspection of the element, exception, and execution of monadic
    --   actions before deciding the 'Action' to take.

-- | Allocation, cleanup, and work actions for parallel processing. These
-- should be passed to an appropriate @bracketOnError@ function.
data BracketOnError m r
    = Bracket
    { allocate :: IO [Weak ThreadId]
    -- ^ Allocation action that spawn threads and sets up handlers.
    , cleanup :: [Weak ThreadId] -> IO ()
    -- ^ Cleanup action that handles exceptional termination
    , action :: m r
    -- ^ Action that performs actual processing and waits for processing to
    --   finish and threads to terminate.
    }

-- | Convenience function for changing the monad the exception handler runs in.
mapHandler :: (m Action -> n Action) -> Handler m a -> Handler n a
mapHandler _ (Simple act) = Simple act
mapHandler mmorph (Handle f) = Handle $ \a exc -> mmorph (f a exc)

-- Workhorse function for runParallel_ and runParallel. Spawns threads, sets up
-- error handling, thread termination, etc.
parallelCore
    :: forall a m
     . MonadIO m
    => Handler IO a
    -> Int
    -> (a -> IO ())
    -> m (IO [Weak ThreadId], [Weak ThreadId] -> IO (), a -> IO (), m ())
parallelCore hndl threads f = liftIO $ do
    originTid <- myThreadId
    inChanIn <- newBroadcastChan
    inChanOut <- newBChanListener inChanIn
    shutdownSem <- newQSemN 0
    endSem <- newQSemN 0

    let bufferValue :: a -> IO ()
        bufferValue = void . writeBChan inChanIn

        simpleHandler :: a -> SomeException -> Action -> IO ()
        simpleHandler val exc act = case act of
            Drop -> return ()
            Retry -> unsafeWriteBChan inChanIn val
            Terminate -> do
                throwTo originTid exc
                myThreadId >>= killThread

        handler :: a -> SomeException -> IO ()
        handler _ exc | Just Shutdown <- fromException exc = throwIO exc
        handler val exc = case hndl of
            Simple a -> simpleHandler val exc a
            Handle h -> h val exc >>= simpleHandler val exc

        processInput :: IO ()
        processInput = do
            x <- readBChan inChanOut
            case x of
                Nothing -> signalQSemN endSem 1
                Just a -> do
                    f a `catch` handler a
                    processInput

        allocate :: IO [Weak ThreadId]
        allocate = liftIO $ do
            tids <- replicateM threads $
                forkFinally processInput (\_ -> signalQSemN shutdownSem 1)
            mapM mkWeakThreadId tids

        cleanup :: [Weak ThreadId] -> IO ()
        cleanup threadIds = liftIO $ do
            mapM_ killWeakThread threadIds
            waitQSemN shutdownSem threads

        wait :: m ()
        wait = do
            closeBChan inChanIn
            liftIO $ waitQSemN endSem threads

    return (allocate, cleanup, bufferValue, wait)
  where
    killWeakThread :: Weak ThreadId -> IO ()
    killWeakThread wTid = do
        tid <- deRefWeak wTid
        case tid of
            Nothing -> return ()
            Just t -> throwTo t Shutdown

-- | Sets up parallel processing.
--
-- The workhorses of this function are the output yielder and \"stream\"
-- processing functions.
--
-- The output yielder is responsible for handling the produced @b@ values,
-- which if can either yield downstream ('Left') when used with something like
-- @conduit@ or @pipes@, or fold into a single results ('Right') when used to
-- run IO in parallel.
--
-- The stream processing function gets two arguments:
--
--     [@a -> m ()@] Should be used to buffer a number of elements equal to the
--                   number of threads.
--
--     [@a -> m b@] Which should be used to process the remainder of the
--                  element stream via, for example, 'Data.Conduit.mapM'.
--
-- See "BroadcastChan" or @broadcast-chan-conduit@ for examples.
--
-- The returned 'BracketOnError' has a 'allocate' action that takes care of
-- setting up 'forkIO' threads and exception handlers. The 'cleanup' action
-- ensures all threads are terminate in case of an exception. Finally, 'action'
-- performs the actual parallel processing of elements.
runParallel
    :: forall a b m n r
     . (MonadIO m, MonadIO n)
    => Either (b -> n r) (r -> b -> n r)
    -- ^ Output yielder
    -> Handler IO a
    -- ^ Parallel processing exception handler
    -> Int
    -- ^ Number of threads to use
    -> (a -> IO b)
    -- ^ Function to run in parallel
    -> ((a -> m ()) -> (a -> m b) -> n r)
    -- ^ \"Stream\" processing function
    -> n (BracketOnError n r)
runParallel yielder hndl threads work pipe = do
    outChanIn <- newBroadcastChan
    outChanOut <- newBChanListener outChanIn

    let process :: MonadIO f => a -> f ()
        process = liftIO . (work >=> void . writeBChan outChanIn)

    (allocate, cleanup, bufferValue, wait) <- parallelCore hndl threads process

    let queueAndYield :: a -> m b
        queueAndYield x = do
            Just v <- liftIO $ readBChan outChanOut <* bufferValue x
            return v

        finish :: r -> n r
        finish r = do
            wait
            closeBChan outChanIn
            next <- readBChan outChanOut
            case next of
                Nothing -> return r
                Just v -> go v r
          where
            go :: b -> r -> n r
            go b z = do
                result <- readBChan outChanOut
                case result of
                    Nothing -> foldFun z b
                    Just x -> foldFun z b >>= go x

        action :: n r
        action = pipe process queueAndYield >>= finish

    return Bracket{allocate,cleanup,action}
  where
    foldFun = case yielder of
        Left g -> const g
        Right g -> g

-- | Sets up parallel processing for functions where we ignore the result.
--
-- The stream processing argument is the workhorse of this function. It gets a
-- (rate-limited) function @a -> m ()@ that queues @a@ values for processing.
-- This function should be applied to all @a@ elements that should be
-- processed. This would be either a partially applied 'Control.Monad.forM_'
-- for parallel processing, or something like conduit's 'Data.Conduit.mapM_' to
-- construct a \"sink\" for @a@ values. See "BroadcastChan" or
-- @broadcast-chan-conduit@ for examples.
--
-- The returned 'BracketOnError' has a 'allocate' action that takes care of
-- setting up 'forkIO' threads and exception handlers. The 'cleanup' action
-- ensures all threads are terminate in case of an exception. Finally, 'action'
-- performs the actual parallel processing of elements.
runParallel_
    :: (MonadIO m, MonadIO n)
    => Handler IO a
    -- ^ Parallel processing exception handler
    -> Int
    -- ^ Number of threads to use
    -> (a -> IO ())
    -- ^ Function to run in parallel
    -> ((a -> m ()) -> n r)
    -- ^ \"Stream\" processing function
    -> n (BracketOnError n r)
runParallel_ hndl threads workFun processElems = do
    sem <- liftIO $ newQSem threads

    let process x = signalQSem sem >> workFun x

    (allocate, cleanup, bufferValue, wait) <- parallelCore hndl threads process

    let action = do
            result <- processElems $ \v -> liftIO $ do
                waitQSem sem
                bufferValue v
            wait
            return result

    return Bracket{allocate,cleanup,action}
