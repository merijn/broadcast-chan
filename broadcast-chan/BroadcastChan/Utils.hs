{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE Safe #-}
module BroadcastChan.Utils
    ( Action(..)
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

data Action = Drop | Retry | Terminate deriving (Eq, Show)

data Handler m a
    = Simple Action
    | Handle (a -> SomeException -> m Action)

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

runParallel
    :: forall a b m n r
     . (MonadIO m, MonadIO n)
    => Either (b -> n r) (r -> b -> n r)
    -> Handler IO a
    -> Int
    -> (a -> IO b)
    -> ((a -> m ()) -> (a -> m b) -> n r)
    -> n (IO [Weak ThreadId], [Weak ThreadId] -> IO (), n r)
runParallel yielder hndl threads work pipe = do
    outChanIn <- newBroadcastChan
    outChanOut <- newBChanListener outChanIn

    let process :: MonadIO f => a -> f ()
        process = liftIO . (work >=> void . writeBChan outChanIn)

    (alloc, cleanup, bufferValue, wait) <- parallelCore hndl threads process

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

    return (alloc, cleanup, pipe process queueAndYield >>= finish)
  where
    foldFun = case yielder of
        Left g -> const g
        Right g -> g

runParallel_
    :: forall a m n r
     . (MonadIO m, MonadIO n)
    => Handler IO a
    -> Int
    -> (a -> IO ())
    -> ((a -> m ()) -> n r)
    -> n (IO [Weak ThreadId], [Weak ThreadId] -> IO (), n r)
runParallel_ hndl threads workFun processElems = do
    sem <- liftIO $ newQSem threads

    let process :: a -> IO ()
        process x = signalQSem sem >> workFun x

    (alloc, cleanup, bufferValue, wait) <- parallelCore hndl threads process

    let rateLimitedWork = do
            result <- processElems $ \v -> liftIO $ do
                waitQSem sem
                bufferValue v
            wait
            return result

    return (alloc, cleanup, rateLimitedWork)
