{-# LANGUAGE BangPatterns #-}
import Criterion.Main

import Control.Concurrent (forkIO, setNumCapabilities, yield)
import Control.Concurrent.Async hiding (wait)
import qualified Control.Concurrent.Async as Async
import Control.Concurrent.Chan
import Control.Concurrent.MVar
import Control.Concurrent.QSem
import Control.Concurrent.QSemN
import Control.Concurrent.STM
import Control.Concurrent.STM.TSem
import Control.DeepSeq (NFData(..))
import Control.Monad (replicateM, replicateM_, void, when)
import Data.Atomics.Counter
import Data.IORef
import Data.Function ((&))
import GHC.Conc (getNumProcessors)

instance NFData (IO a) where
    rnf !_ = ()

benchSync :: (Int -> IO (IO (), IO ())) -> Int -> Benchmarkable
benchSync alloc i = perRunEnv setup $ \(start, wait) -> do
    putMVar start ()
    wait
  where
    setup = do
        start <- newEmptyMVar
        (signal, wait) <- alloc i
        replicateM_ i . forkIO $ do
            void $ readMVar start
            signal
        return (start, wait)
{-# INLINE benchSync #-}

benchSTM :: (Int -> IO (STM (), STM ())) -> Int -> Benchmarkable
benchSTM alloc = benchSync $ \i -> do
    (signal, wait) <- alloc i
    return (atomically signal, atomically wait)
{-# INLINE benchSTM #-}

generalSync :: (a -> Int -> Benchmarkable) -> String -> a -> Int -> Benchmark
generalSync build s alloc i = bench s $ build alloc i
{-# INLINE generalSync #-}

syncGeneral :: String -> (Int -> IO (IO (), IO ())) -> Int -> Benchmark
syncGeneral = generalSync benchSync
{-# INLINE syncGeneral #-}

syncSTM :: String -> (Int -> IO (STM (), STM ())) -> Int -> Benchmark
syncSTM = generalSync benchSTM
{-# INLINE syncSTM #-}

syncSingleWaitSTM :: String -> (IO (STM (), STM ())) -> Int -> Benchmark
syncSingleWaitSTM s alloc = bgroup s . sequence
    [ bench "single transaction" . benchSTM singleTransaction
    , bench "multi transaction" . benchSync multiTransaction
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

syncAsync :: Int -> Benchmark
syncAsync = generalSync run "Async" ()
  where
    setup i = do
        start <- newEmptyMVar
        threads <- replicateM i . async $ readMVar start
        return (start, mapM_ Async.wait threads)
    {-# INLINE setup #-}

    run () i = perRunEnv (setup i) $ \(start, wait) -> do
        putMVar start()
        wait
    {-# INLINE run #-}
{-# INLINE syncAsync #-}

syncAtomicCounter :: Int -> Benchmark
syncAtomicCounter = syncGeneral "AtomicCounter" $ \i -> do
    cnt <- newCounter 0
    let spinLoop = do
            n <- readCounter cnt
            yield
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
            n <- atomicModifyIORef' ref $ \n -> (n, n)
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

syncTChan :: Int -> Benchmark
syncTChan = syncSingleWaitSTM "TChan" $ do
    tchan <- newTChanIO
    return (writeTChan tchan (), readTChan tchan)
{-# INLINE syncTChan #-}

syncTMVar :: Int -> Benchmark
syncTMVar = syncGeneral "TMVar" $ \i -> do
    tmvar <- newEmptyTMVarIO
    let signal = atomically $ putTMVar tmvar ()
        wait = replicateM_ i . atomically $ takeTMVar tmvar
    return (signal, wait)
{-# INLINE syncTMVar #-}

syncTQueue :: Int -> Benchmark
syncTQueue = syncSingleWaitSTM "TQueue" $ do
    tqueue <- newTQueueIO
    return (writeTQueue tqueue (), readTQueue tqueue)
{-# INLINE syncTQueue #-}

syncTSem :: Int -> Benchmark
syncTSem = syncSingleWaitSTM "TSem" $ do
    tsem <- atomically $ newTSem 0
    return (signalTSem tsem, waitTSem tsem)
{-# INLINE syncTSem #-}

syncTVar :: Int -> Benchmark
syncTVar = syncSTM "TVar" $ \i -> do
    tvar <- newTVarIO 0
    return (modifyTVar' tvar (+1), check . (==i) =<< readTVar tvar)
{-# INLINE syncTVar #-}

benchThreads :: Int -> Benchmark
benchThreads i = bgroup (show i ++ " threads") $ i & sequence
    [ syncAsync
    , syncAtomicCounter
    , syncChan
    , syncIORef
    , syncMVar
    , syncQSem
    , syncQSemN
    , syncTChan
    , syncTMVar
    , syncTVar
    , syncTQueue
    , syncTSem
    ]

main :: IO ()
main = do
    getNumProcessors >>= setNumCapabilities
    defaultMain $ map benchThreads [1, 2, 5, 10, 100, 1000, 10000]
