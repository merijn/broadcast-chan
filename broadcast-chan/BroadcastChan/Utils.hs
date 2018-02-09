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
    (ThreadId, forkIOWithUnmask, killThread, mkWeakThreadId, myThreadId)
import Control.Concurrent.MVar
import Control.Concurrent.QSem
import Control.Concurrent.QSemN
import Control.Exception (SomeException(..), catch, mask_, throwTo)
import Control.Monad ((>=>), join, replicateM, void)
import Control.Monad.IO.Class (MonadIO(..))
import System.Mem.Weak (Weak, deRefWeak)

import BroadcastChan.Internal

-- DANGER! Breaks the invariant that you can't write to closed channels!
-- Only meant to be used in 'parallelCore'!
unsafeWriteBChan :: BroadcastChan In a -> a -> IO ()
unsafeWriteBChan (BChan writeVar) val = do
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

    return . pBracketOnError (allocate processInput) cleanup $ \_ -> do
        result <- work bufferValue
        liftIO $ do
            closeBChan inChanIn
            waitQSemN endSem threads
        finalise result
  where
    allocate :: IO () -> n [Weak ThreadId]
    allocate processInput = liftIO $ do
        tids <- replicateM threads $ forkIOWithUnmask $ \restore -> do
            restore processInput
        mapM mkWeakThreadId tids

    killWeakThread :: Weak ThreadId -> IO ()
    killWeakThread wTid = do
        tid <- deRefWeak wTid
        case tid of
            Nothing -> return ()
            Just t -> killThread t

    cleanup :: [Weak ThreadId] -> n ()
    cleanup = liftIO . mapM_ killWeakThread

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
    outChanIn <- liftIO newBroadcastChan
    outChanOut <- liftIO $ newBChanListener outChanIn

    let process :: a -> IO ()
        process = work >=> void . writeBChan outChanIn

        yieldAll :: r -> m r
        yieldAll r = do
            next <- liftIO $ do
                closeBChan outChanIn
                readBChan outChanOut
            case next of
                Nothing -> return r
                Just v -> go v r
          where
            go :: b -> r -> m r
            go b z = do
                result <- liftIO $ readBChan outChanOut
                case result of
                    Nothing -> foldFun z b
                    Just x -> foldFun z b >>= go x

    parallelCore bracketOnError hndl threads process yieldAll $ \bufferValue ->
        let queueAndYield :: a -> f b
            queueAndYield x = do
                Just v <- liftIO $ readBChan outChanOut <* bufferValue x
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
