{-# LANGUAGE CPP #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE Safe #-}
module BroadcastChan.Utils
    ( Action(..)
    , Handler(..)
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
import Control.Monad ((>=>), join, replicateM, void)
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

data Handler a
    = Simple Action
    | Handle (a -> SomeException -> IO Action)

-- Workhorse function for runParallel_ and runParallel. Spawns threads, sets up
-- error handling, thread termination, etc.
parallelCore
    :: forall a m n r . (MonadIO m, MonadIO n)
    => (forall x . n x -> (x -> n ()) -> (x -> m r) -> m r)
    -> Handler a
    -> Int
    -> (a -> IO ())
    -> (r -> m r)
    -> ((a -> IO ()) -> m r)
    -> m r
parallelCore pBracketOnError hndl threads f finalise work = join . liftIO $ do
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

        allocate :: n [Weak ThreadId]
        allocate = liftIO $ do
            tids <- replicateM threads $
                forkFinally processInput (\_ -> signalQSemN shutdownSem 1)
            mapM mkWeakThreadId tids

        cleanup :: [Weak ThreadId] -> n ()
        cleanup threadIds = liftIO $ do
            mapM_ killWeakThread threadIds
            waitQSemN shutdownSem threads

    return . pBracketOnError allocate cleanup $ \_ -> do
        result <- work bufferValue
        closeBChan inChanIn
        liftIO $ waitQSemN endSem threads
        finalise result
  where
    killWeakThread :: Weak ThreadId -> IO ()
    killWeakThread wTid = do
        tid <- deRefWeak wTid
        case tid of
            Nothing -> return ()
            Just t -> throwTo t Shutdown

runParallel
    :: forall a b f m n r . (MonadIO f, MonadIO m, MonadIO n)
    => (forall x . n x -> (x -> n ()) -> (x -> m r) -> m r)
    -> ((a -> f ()) -> (a -> f b) -> m r)
    -> Either (b -> m r) (r -> b -> m r)
    -> Handler a
    -> Int
    -> (a -> IO b)
    -> m r
runParallel bracketOnError run yielder hndl threads work = do
    outChanIn <- newBroadcastChan
    outChanOut <- newBChanListener outChanIn

    let process :: a -> IO ()
        process = work >=> void . writeBChan outChanIn

        yieldAll :: r -> m r
        yieldAll r = do
            next <- do
                closeBChan outChanIn
                readBChan outChanOut
            case next of
                Nothing -> return r
                Just v -> go v r
          where
            go :: b -> r -> m r
            go b z = do
                result <- readBChan outChanOut
                case result of
                    Nothing -> foldFun z b
                    Just x -> foldFun z b >>= go x

    parallelCore bracketOnError hndl threads process yieldAll $ \bufferValue ->
        let queueAndYield :: a -> f b
            queueAndYield x = do
                Just v <- readBChan outChanOut <* liftIO (bufferValue x)
                return v
        in run (liftIO . bufferValue) queueAndYield
  where
    foldFun = case yielder of
        Left g -> const g
        Right g -> g

runParallel_
    :: forall a f m n r . (MonadIO f, MonadIO m, MonadIO n)
    => (forall x . n x -> (x -> n ()) -> (x -> m r) -> m r)
    -> ((a -> f ()) -> m r)
    -> Handler a
    -> Int
    -> (a -> IO ())
    -> m r
runParallel_ bracketOnError run hndl threads work = do
    sem <- liftIO $ newQSem threads

    let process :: a -> IO ()
        process x = signalQSem sem >> work x

    parallelCore bracketOnError hndl threads process return $ \bufferValue ->
        let rateLimitedBuffer :: a -> f ()
            rateLimitedBuffer x = liftIO $ do
                waitQSem sem
                bufferValue x
        in run rateLimitedBuffer
