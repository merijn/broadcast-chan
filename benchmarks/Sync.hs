{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleInstances #-}
import Criterion.Main

import Control.Concurrent (forkIO)
import Control.Concurrent.Chan
import Control.Concurrent.MVar
import Control.Concurrent.QSem
import Control.Concurrent.QSemN
import Control.Concurrent.STM
import Control.Concurrent.STM.TSem
import Control.DeepSeq (NFData(..))
import Control.Monad (replicateM_, void, when)
import Data.Atomics.Counter
import Data.IORef
import Data.Monoid ((<>))

instance NFData (IO ()) where
    rnf !_ = ()

syncGeneral :: String -> (Int -> IO (IO (), IO ())) -> Int -> Benchmark
syncGeneral s alloc i = bench name . perRunEnv setup $ \(start, wait) -> do
    putMVar start ()
    wait
  where
    name = s ++ " " ++ show i
    setup = do
        start <- newEmptyMVar
        (signal, wait) <- alloc i
        replicateM_ i . forkIO $ do
            void $ readMVar start
            signal
        return (start, wait)
{-# INLINE syncGeneral #-}

syncSTM :: String -> (Int -> IO (STM (), STM ())) -> Int -> Benchmark
syncSTM s alloc = syncGeneral s $ \i -> do
    (signal, wait) <- alloc i
    return (atomically signal, atomically wait)
{-# INLINE syncSTM #-}

syncSingleWaitSTM :: String -> (IO (STM (), STM ())) -> Int -> [Benchmark]
syncSingleWaitSTM s alloc = sequence
    [ syncSTM s singleTransaction
    , syncGeneral (s++"2") multiTransaction
    ]
  where
    singleTransaction :: Int -> IO (STM (), STM ())
    singleTransaction i = do
        (signal, wait) <- alloc
        return (signal, replicateM_ i wait)
    {-# INLINE singleTransaction #-}

    multiTransaction :: Int -> IO (IO (), IO ())
    multiTransaction i = do
        (signal, wait) <- alloc
        return (atomically signal, replicateM_ i (atomically wait))
    {-# INLINE multiTransaction #-}
{-# INLINE syncSingleWaitSTM #-}

syncAtomicCounter :: Int -> Benchmark
syncAtomicCounter = syncGeneral "AtomicCounter" $ \i -> do
    cnt <- newCounter 0
    let spinLoop = do
            n <- readCounter cnt
            when (n /= i) spinLoop
        {-# INLINE spinLoop #-}
    return (void (incrCounter 1 cnt), spinLoop)
{-# INLINE syncAtomicCounter #-}

syncChan :: Int -> Benchmark
syncChan = syncGeneral "Chan" $ \i -> do
    chan <- newChan
    return (writeChan chan (), replicateM_ i (readChan chan))
{-# INLINE syncChan #-}

syncIORef :: Int -> Benchmark
syncIORef = syncGeneral "IORef" $ \i -> do
    ref <- newIORef 0
    let spinLoop = do
            n <- readIORef ref
            when (n /= i) spinLoop
        {-# INLINE spinLoop #-}
    return (atomicModifyIORef' ref (\n -> (n+1, ())), spinLoop)
{-# INLINE syncIORef #-}

syncMVar :: Int -> Benchmark
syncMVar = syncGeneral "MVar" $ \i -> do
    mvar <- newEmptyMVar
    return (putMVar mvar (), replicateM_ i (takeMVar mvar))
{-# INLINE syncMVar #-}

syncQSem :: Int -> Benchmark
syncQSem = syncGeneral "QSem" $ \i -> do
    qsem <- newQSem 0
    return (signalQSem qsem, replicateM_ i (waitQSem qsem))
{-# INLINE syncQSem #-}

syncQSemN :: Int -> Benchmark
syncQSemN = syncGeneral "QSemN" $ \i -> do
    qsemn <- newQSemN 0
    return (signalQSemN qsemn 1, waitQSemN qsemn i)
{-# INLINE syncQSemN #-}

syncTBQueue :: Int -> [Benchmark]
syncTBQueue i = syncSingleWaitSTM "TBQueue" act i
  where
    act = do
        tbqueue <- newTBQueueIO i
        return (writeTBQueue tbqueue (), readTBQueue tbqueue)
{-# INLINE syncTBQueue #-}

syncTChan :: Int -> [Benchmark]
syncTChan = syncSingleWaitSTM "TChan" $ do
    tchan <- newTChanIO
    return (writeTChan tchan (), readTChan tchan)
{-# INLINE syncTChan #-}

syncTMVar :: Int -> [Benchmark]
syncTMVar = syncSingleWaitSTM "TMVar" $ do
    tmvar <- newEmptyTMVarIO
    return (putTMVar tmvar (), takeTMVar tmvar)
{-# INLINE syncTMVar #-}

syncTQueue :: Int -> [Benchmark]
syncTQueue = syncSingleWaitSTM "TQueue" $ do
    tqueue <- newTQueueIO
    return (writeTQueue tqueue (), readTQueue tqueue)
{-# INLINE syncTQueue #-}

syncTSem :: Int -> [Benchmark]
syncTSem = syncSingleWaitSTM "TSem" $ do
    tsem <- atomically $ newTSem 0
    return (signalTSem tsem, waitTSem tsem)
{-# INLINE syncTSem #-}

syncTVar :: Int -> Benchmark
syncTVar = syncSTM "TVar" $ \i -> do
    tvar <- newTVarIO 0
    return (modifyTVar' tvar (+1), check . (==i) =<< readTVar tvar)
{-# INLINE syncTVar #-}

syncAll :: Int -> [Benchmark]
syncAll = sequence singleBenchmarks <> mconcat multiBenchmarks
  where
    singleBenchmarks =
      [ syncAtomicCounter
      , syncChan
      , syncIORef
      , syncMVar
      , syncQSem
      , syncQSemN
      , syncTVar
      ]

    multiBenchmarks =[ syncTBQueue, syncTChan, syncTMVar, syncTQueue, syncTSem]
{-# INLINE syncAll #-}

main :: IO ()
main = do
    defaultMain
      [ bgroup "Synchronisation" $ syncAll 5 ]
