{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NumDecimals #-}
{-# LANGUAGE RecordWildCards #-}
import Criterion.Main

import Control.Concurrent (setNumCapabilities)
import Control.Concurrent.Async
import Control.Concurrent.BroadcastChan
import Control.Concurrent.Chan
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.DeepSeq (NFData(..))
import Control.Monad (forM, guard, replicateM, void)
import qualified Control.Monad as Monad
import Data.Bifunctor (second)
import Data.Int (Int64)
import GHC.Conc (getNumProcessors)
import GHC.Generics (Generic)

instance NFData (BroadcastChan io a) where
    rnf !_ = ()

instance NFData (IO a) where
    rnf !_ = ()

replicateM_ :: Monad m => Int64 -> m a -> m ()
replicateM_ = Monad.replicateM_ . fromIntegral

splitEqual :: Integral a => a -> a -> [a]
splitEqual _ 0 = []
splitEqual total n =
  replicate rest (base + 1) ++ replicate (fromIntegral n - rest) base
  where
    (base, rest) = second fromIntegral $ total `quotRem` n

data Config
    = Config
    { writers :: Int
    , readers :: Int
    , numMsgs :: Int64
    , broadcast :: Bool
    }

data ChanOps
    = ChanOps
    { putChan :: !(IO ())
    , takeChan :: !(IO ())
    , dupTake :: !(IO (IO ()))
    } deriving (Generic, NFData)

data ChanType
    = Chan
    { chanName :: String
    , canBroadcast :: Bool
    , allocChan :: Int64 -> Int64 -> IO ChanOps
    }

benchBChan :: ChanType
benchBChan = Chan "BroadcastChan" True $ \_size numMsgs -> do
    chan <- newBroadcastChan
    listener <- newBChanListener chan
    replicateM_ numMsgs $ writeBChan chan ()
    return ChanOps
        { putChan = void $ writeBChan chan ()
        , takeChan = void $ readBChan listener
        , dupTake = void . readBChan <$> newBChanListener chan
        }
{-# INLINE benchBChan #-}

benchBChanExcept :: ChanType
benchBChanExcept = Chan "BroadcastChan (except)" True $ \_size numMsgs -> do
    chan <- newBroadcastChan
    listener <- newBChanListener chan
    replicateM_ numMsgs $ writeBChan chan ()
    return (writeBChan_ chan (), readBChan_ listener)
    return ChanOps
        { putChan = writeBChan_ chan ()
        , takeChan = readBChan_ listener
        , dupTake = readBChan_ <$> newBChanListener chan
        }
{-# INLINE benchBChanExcept #-}

benchBChanDrop :: ChanType
benchBChanDrop = Chan "BroadcastChan (drop)" False $ \_ _ -> do
    chan <- newBroadcastChan
    return ChanOps
        { putChan = void $ writeBChan chan ()
        , takeChan = fail "Dropping BroadcastChan doesn't support reading."
        , dupTake = fail "Dropping BroadcastChan doesn't support broadcasting."
        }
{-# INLINE benchBChanDrop #-}

benchBChanDropExcept :: ChanType
benchBChanDropExcept = Chan "BroadcastChan (drop-except)" False $ \_ _ -> do
    chan <- newBroadcastChan
    return ChanOps
        { putChan = writeBChan_ chan ()
        , takeChan = fail "Dropping BroadcastChan doesn't support reading."
        , dupTake = fail "Dropping BroadcastChan doesn't support broadcasting."
        }
{-# INLINE benchBChanDropExcept #-}

benchChan :: ChanType
benchChan = Chan "Chan" True $ \_size numMsgs -> do
    chan <- newChan
    replicateM_ numMsgs $ writeChan chan ()
    return ChanOps
        { putChan = writeChan chan ()
        , takeChan = readChan chan
        , dupTake = readChan <$> dupChan chan
        }
{-# INLINE benchChan #-}

benchTChan :: ChanType
benchTChan = Chan "TChan" True $ \_size numMsgs -> do
    chan <- newTChanIO
    replicateM_ numMsgs . atomically $ writeTChan chan ()
    return ChanOps
        { putChan = atomically $ writeTChan chan ()
        , takeChan = atomically $ readTChan chan
        , dupTake = atomically . readTChan <$> atomically (dupTChan chan)
        }
{-# INLINE benchTChan #-}

benchTQueue :: ChanType
benchTQueue = Chan "TQueue" False $ \_size numMsgs -> do
    chan <- newTQueueIO
    replicateM_ numMsgs . atomically $ writeTQueue chan ()
    return ChanOps
        { putChan = atomically $ writeTQueue chan ()
        , takeChan = atomically $ readTQueue chan
        , dupTake = return (fail "TQueue doesn't support broadcasting")
        }
{-# INLINE benchTQueue #-}

benchTBQueue :: ChanType
benchTBQueue = Chan "TBQueue" False $ \size numMsgs -> do
    chan <- newTBQueueIO (fromIntegral size)
    replicateM_ numMsgs . atomically $ writeTBQueue chan ()
    return ChanOps
        { putChan = atomically $ writeTBQueue chan ()
        , takeChan = atomically $ readTBQueue chan
        , dupTake =  return (fail "TBQueue doesn't support broadcasting")
        }
{-# INLINE benchTBQueue #-}

benchWrites :: ChanType -> Benchmark
benchWrites Chan{..} =
  bench chanName $ perBatchEnv (\i -> allocChan i 0) putChan

benchReads :: ChanType -> Benchmark
benchReads Chan{..} =
  bench chanName $ perBatchEnv (\i -> allocChan i i) takeChan

benchConcurrent :: ChanType -> Config -> Benchmark
benchConcurrent Chan{..} Config{..} =
  if broadcast && not canBroadcast
     then bgroup "" []
     else bench name $ perRunEnv setupConcurrent id
  where
    name :: String
    name = show numMsgs ++ " messages"

    splitMsgs :: Integral a => a -> [Int64]
    splitMsgs = splitEqual numMsgs . fromIntegral

    preloadedMsgs :: Int64
    preloadedMsgs
        | writers == 0 = numMsgs
        | otherwise = 0

    launchReaders :: ChanOps -> IO [Async ()]
    launchReaders ChanOps{..}
        | broadcast = replicateM readers $ do
            doTake <- dupTake
            async $ replicateM_ numMsgs doTake

        | otherwise = forM (splitMsgs readers) $ async . \n -> do
            replicateM_ n takeChan

    setupConcurrent :: IO (IO ())
    setupConcurrent = do
        start <- newEmptyMVar
        chan@ChanOps{..} <- allocChan numMsgs preloadedMsgs

        wThreads <- forM (splitMsgs writers) $ async . \n -> do
            readMVar start
            replicateM_ n putChan

        rThreads <- launchReaders chan

        return $ putMVar start () >> mapM_ wait (wThreads ++ rThreads)
{-# INLINE benchConcurrent #-}

runConcurrent :: [Int] -> [Int] -> [Int64] -> Bool -> ChanType -> Benchmark
runConcurrent writerCounts readerCounts msgs broadcast chan =
    bgroup (chanName chan) $ map makeBenchGroup threads
  where
    threads = do
        ws <- writerCounts
        rs <- readerCounts
        guard $ (ws, rs) `notElem` [(0,0),(0,1),(1,0)]
        return (ws, rs)

    makeBenchGroup :: (Int, Int) -> Benchmark
    makeBenchGroup (writers, readers) = bgroup name $ map makeBenchmark msgs
        where
          name :: String
          name | writers == 0 = show readers
               | readers == 0 = show writers
               | otherwise = show writers ++ " to " ++ show readers

          makeBenchmark :: Int64 -> Benchmark
          makeBenchmark numMsgs = benchConcurrent chan Config{..}

chanTypes :: [ChanType]
chanTypes =
  [ benchBChan
  , benchBChanExcept
  , benchChan
  , benchTChan
  , benchTQueue
  , benchTBQueue
  ]

writeChanTypes :: [ChanType]
writeChanTypes = [ benchBChanDrop, benchBChanDropExcept ] ++ chanTypes

main :: IO ()
main = do
  getNumProcessors >>= setNumCapabilities
  defaultMain
    [ bgroup "Write" $ map benchWrites writeChanTypes
    , bgroup "Read" $ map benchReads chanTypes
    , bgroup "Concurrent"
        [ bgroup "Write" $ map (runConcurrentWrites False) writeChanTypes
        , bgroup "Read" $ map (runConcurrentWrites False) chanTypes
        , bgroup "Read-Write" $ map (runConcurrentBench False) chanTypes
        ]
    , bgroup "Concurrent Broadcast"
        [ bgroup "Write" $ map (runConcurrentWrites True) chanTypes
        , bgroup "Read" $ map (runConcurrentReads True) chanTypes
        , bgroup "Read-Write" $ map (runConcurrentBench True) chanTypes
        ]
    ]
  where
    threadCounts = [1,2,5,10,100,1000,1e4]
    msgCounts = [100,1000,1e4,1e5,1e6]

    runConcurrentBench = runConcurrent threadCounts threadCounts msgCounts
    runConcurrentWrites = runConcurrent threadCounts [0] msgCounts
    runConcurrentReads = runConcurrent [0] threadCounts msgCounts
