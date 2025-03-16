{-# OPTIONS_HADDOCK not-home #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE Safe #-}
-------------------------------------------------------------------------------
-- |
-- Module      :  BroadcastChan.Extra
-- Copyright   :  (C) 2014-2022 Merijn Verstraaten
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
    , ThreadBracket(..)
    , mapHandler
    , runParallel
    , runParallelWith
    , runParallel_
    , runParallelWith_
    ) where

import Control.Concurrent (ThreadId, forkFinally, mkWeakThreadId, myThreadId)
import Control.Concurrent.MVar
import Control.Concurrent.QSem
import Control.Concurrent.QSemN
import Control.Exception (Exception(..), SomeException(..), bracketOnError)
import qualified Control.Exception as Exc
import Control.Monad ((>=>), join, replicateM, void)
import Control.Monad.Trans.Cont (ContT(..))
import Control.Monad.IO.Unlift (MonadIO(..))
import Data.Typeable (Typeable)
import System.Mem.Weak (Weak, deRefWeak)

import BroadcastChan.Internal

evalContT :: Monad m => ContT r m r -> m r
evalContT m = runContT m return

-- DANGER! Breaks the invariant that you can't write to closed channels!
-- Only meant to be used in 'parallelCore'!
unsafeWriteBChan :: MonadIO m => BroadcastChan In a -> a -> m ()
unsafeWriteBChan (BChan writeVar) val = liftIO $ do
  new_hole <- newEmptyMVar
  Exc.mask_ $ do
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
--
-- @since 0.2.0
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
--
-- @since 0.2.0
data Handler m a
    = Simple Action
    -- ^ Always take the specified 'Action'.
    | Handle (a -> SomeException -> m Action)
    -- ^ Allow inspection of the element, exception, and execution of monadic
    --   actions before deciding the 'Action' to take.

-- | Allocation, cleanup, and work actions for parallel processing. These
-- should be passed to an appropriate @bracketOnError@ function.
--
-- @since 0.2.0
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

-- | Datatype for specifying additional setup/cleanup around forking threads.
-- Used by 'runParallelWith' and 'runParallelWith_' to fix resource management
-- in @broadcast-chan-conduit@.
--
-- If the allocation action can fail/abort with an exception it __MUST__ take
-- care not to leak resources in these cases. In other words, IFF 'setupFork'
-- succeeds then this library will ensure the corresponding cleanup runs.
--
-- @since 0.2.1
data ThreadBracket
    = ThreadBracket
    { setupFork :: IO ()
    -- ^ Setup action to run before spawning a new thread.
    , cleanupFork :: IO ()
    -- ^ Normal cleanup action upon thread termination.
    , cleanupForkError :: IO ()
    -- ^ Exceptional cleanup action in case thread terminates due to an
    -- exception.
    }

noopBracket :: ThreadBracket
noopBracket = ThreadBracket
    { setupFork = return ()
    , cleanupFork = return ()
    , cleanupForkError = return ()
    }

-- | Convenience function for changing the monad the exception handler runs in.
--
-- @since 0.2.0
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
    -> IO ()
    -> ThreadBracket
    -> (a -> IO ())
    -> m (IO [Weak ThreadId], [Weak ThreadId] -> IO (), a -> IO (), m ())
parallelCore hndl threads onDrop threadBracket f = liftIO $ do
    originTid <- myThreadId
    inChanIn <- newBroadcastChan
    inChanOut <- newBChanListener inChanIn
    shutdownSem <- newQSemN 0
    endSem <- newQSemN 0
    excMVar <- newMVar (Exc.throwTo originTid)

    let bufferValue :: a -> IO ()
        bufferValue = void . writeBChan inChanIn

        simpleHandler :: a -> SomeException -> Action -> IO ()
        simpleHandler val exc act = case act of
            Drop -> onDrop
            Retry -> unsafeWriteBChan inChanIn val
            Terminate -> Exc.throwIO exc

        handler :: a -> SomeException -> IO ()
        handler _ exc | Just Shutdown <- fromException exc = Exc.throwIO exc
        handler val exc = case hndl of
            Simple a -> simpleHandler val exc a
            Handle h -> h val exc >>= simpleHandler val exc

        processInput :: IO ()
        processInput = do
            x <- readBChan inChanOut
            case x of
                Nothing -> signalQSemN endSem 1
                Just a -> do
                    f a `Exc.catch` handler a
                    processInput

        unsafeAllocThread :: IO (Weak ThreadId)
        unsafeAllocThread = do
            setupFork
            tid <- forkFinally processInput $ \exit -> do
                signalQSemN shutdownSem 1
                case exit of
                    Left exc
                      | Just Shutdown <- fromException exc -> cleanupForkError
                      | otherwise -> do
                          cleanupForkError
                          reportErr <- tryTakeMVar excMVar
                          case reportErr of
                              Nothing -> return ()
                              Just throw -> throw exc `Exc.catch` shutdownHandler
                    Right () -> cleanupFork

            mkWeakThreadId tid
          where
            shutdownHandler Shutdown = return ()

        allocThread :: ContT r IO (Weak ThreadId)
        allocThread = ContT $ bracketOnError unsafeAllocThread killWeakThread

        allocateThreads :: IO [Weak ThreadId]
        allocateThreads = evalContT $ replicateM threads allocThread

        cleanup :: [Weak ThreadId] -> IO ()
        cleanup threadIds = liftIO . Exc.uninterruptibleMask_ $ do
            mapM_ killWeakThread threadIds
            waitQSemN shutdownSem threads

        wait :: m ()
        wait = do
            closeBChan inChanIn
            liftIO $ waitQSemN endSem threads

    return (allocateThreads, cleanup, bufferValue, wait)
  where
    ThreadBracket{setupFork,cleanupFork,cleanupForkError} = threadBracket

    killWeakThread :: Weak ThreadId -> IO ()
    killWeakThread wTid = do
        tid <- deRefWeak wTid
        case tid of
            Nothing -> return ()
            Just t -> Exc.throwTo t Shutdown

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
-- setting up 'Control.Concurrent.forkIO' threads and exception handlers. The
-- 'cleanup' action ensures all threads are terminate in case of an exception.
-- Finally, 'action' performs the actual parallel processing of elements.
--
-- @since 0.2.0
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
    -> ((a -> m ()) -> (a -> m (Maybe b)) -> n r)
    -- ^ \"Stream\" processing function
    -> n (BracketOnError n r)
runParallel = runParallelWith noopBracket

-- | Like 'runParallel', but accepts a setup and cleanup action that will be
-- run before spawning a new thread and upon thread exit respectively.
--
-- The main use case is to properly manage the resource reference counts of
-- 'Control.Monad.Trans.Resource.ResourceT'.
--
-- If the setup throws an 'IO' exception or otherwise aborts, it __MUST__
-- ensure any allocated resource are freed. If it completes without an
-- exception, the cleanup is guaranteed to run (assuming proper use of
-- bracketing with the returned 'BracketOnError').
--
-- @since 0.2.1
runParallelWith
    :: forall a b m n r
     . (MonadIO m, MonadIO n)
    => ThreadBracket
    -- ^ Bracketing action used to manage resources across thread spawns
    -> Either (b -> n r) (r -> b -> n r)
    -- ^ Output yielder
    -> Handler IO a
    -- ^ Parallel processing exception handler
    -> Int
    -- ^ Number of threads to use
    -> (a -> IO b)
    -- ^ Function to run in parallel
    -> ((a -> m ()) -> (a -> m (Maybe b)) -> n r)
    -- ^ \"Stream\" processing function
    -> n (BracketOnError n r)
runParallelWith threadBracket yielder hndl threads work pipe = do
    outChanIn <- newBroadcastChan
    outChanOut <- newBChanListener outChanIn

    let process :: MonadIO f => a -> f ()
        process = liftIO . (work >=> void . writeBChan outChanIn . Just)

        notifyDrop :: IO ()
        notifyDrop = void $ writeBChan outChanIn Nothing

    (allocate, cleanup, bufferValue, wait) <-
        parallelCore hndl threads notifyDrop threadBracket process

    let queueAndYield :: a -> m (Maybe b)
        queueAndYield x = do
            v <- join <$> liftIO (readBChan outChanOut <* bufferValue x)
            return v

        finish :: r -> n r
        finish r = do
            next <- readBChan outChanOut
            case next of
                Nothing -> return r
                Just Nothing -> finish r
                Just (Just v) -> foldFun r v >>= finish

        action :: n r
        action = do
            result <- pipe (liftIO . bufferValue) queueAndYield
            wait
            closeBChan outChanIn
            finish result

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
-- setting up 'Control.Concurrent.forkIO' threads and exception handlers. Th
-- 'cleanup' action ensures all threads are terminate in case of an exception.
-- Finally, 'action' performs the actual parallel processing of elements.
--
-- @since 0.2.0
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
runParallel_ = runParallelWith_ noopBracket

-- | Like 'runParallel_', but accepts a setup and cleanup action that will be
-- run before spawning a new thread and upon thread exit respectively.
--
-- The main use case is to properly manage the resource reference counts of
-- 'Control.Monad.Trans.Resource.ResourceT'.
--
-- If the setup throws an 'IO' exception or otherwise aborts, it __MUST__
-- ensure any allocated resource are freed. If it completes without an
-- exception, the cleanup is guaranteed to run (assuming proper use of
-- bracketing with the returned 'BracketOnError').
--
-- @since 0.2.1
runParallelWith_
    :: (MonadIO m, MonadIO n)
    => ThreadBracket
    -- ^ Bracketing action used to manage resources across thread spawns
    -> Handler IO a
    -- ^ Parallel processing exception handler
    -> Int
    -- ^ Number of threads to use
    -> (a -> IO ())
    -- ^ Function to run in parallel
    -> ((a -> m ()) -> n r)
    -- ^ \"Stream\" processing function
    -> n (BracketOnError n r)
runParallelWith_ threadBracket hndl threads workFun processElems = do
    sem <- liftIO $ newQSem threads

    let process x = signalQSem sem >> workFun x

    (allocate, cleanup, bufferValue, wait) <-
        parallelCore hndl threads (return ()) threadBracket process

    let action = do
            result <- processElems $ \v -> liftIO $ do
                waitQSem sem
                bufferValue v
            wait
            return result

    return Bracket{allocate,cleanup,action}
