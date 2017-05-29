{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NumDecimals #-}
{-# LANGUAGE RecordWildCards #-}
import Criterion.Main

import Control.Concurrent (setNumCapabilities)
import Control.Concurrent.Async
import BroadcastChan
import qualified BroadcastChan.Throw as Throw
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
    } deriving (Generic)

instance NFData ChanOps

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
benchBChanExcept = Chan "BroadcastChan.Throw" True $ \_size numMsgs -> do
    chan <- newBroadcastChan
    listener <- newBChanListener chan
    replicateM_ numMsgs $ writeBChan chan ()
    return ChanOps
        { putChan = Throw.writeBChan chan ()
        , takeChan = Throw.readBChan listener
        , dupTake = Throw.readBChan <$> newBChanListener chan
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
benchBChanDropExcept = Chan "BroadcastChan.Throw (drop)" False $ \_ _ -> do
    chan <- newBroadcastChan
    return ChanOps
        { putChan = Throw.writeBChan chan ()
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

benchConcurrent :: Config -> ChanType -> Benchmark
benchConcurrent Config{..} Chan{..} =
  if broadcast && not canBroadcast
     then bgroup "" []
     else bench chanName $ perRunEnv setupConcurrent id
  where
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

runConcurrent
    :: String -> [Int] -> [Int] -> [Int64] -> Bool -> [ChanType] -> Benchmark
runConcurrent typeName writerCounts readerCounts msgs broadcast chans =
    bgroup typeName $ map makeBenchGroup threads
  where
    threads = do
        ws <- writerCounts
        rs <- readerCounts
        guard $ (ws, rs) `notElem` [(0,0),(0,1),(1,0)]
        return (ws, rs)

    makeBenchGroup :: (Int, Int) -> Benchmark
    makeBenchGroup (writers, readers) = bgroup groupName $ map mkBench msgs
        where
          groupName :: String
          groupName
              | writers == 0 = show readers ++ " readers"
              | readers == 0 = show writers ++ " writers"
              | otherwise = show writers ++ " to " ++ show readers

          mkBench :: Int64 -> Benchmark
          mkBench numMsgs =
              bgroup name $ map (benchConcurrent Config{..}) chans
            where
              name = show numMsgs ++ " messages"

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
        [ runConcurrentWrites False writeChanTypes
        , runConcurrentReads False chanTypes
        , runConcurrentBench False chanTypes
        ]
    , bgroup "Broadcast"
        [ runConcurrentWrites True chanTypes
        , runConcurrentReads True chanTypes
        , runConcurrentBench True chanTypes
        ]
    ]
  where
    threads = [1,2,5,10,100,1000,1e4]
    msgCounts = [1e4,1e5,1e6]

    runConcurrentBench = runConcurrent "Read-Write" threads threads msgCounts
    runConcurrentWrites = runConcurrent "Write" threads [0] msgCounts
    runConcurrentReads = runConcurrent "Read" [0] threads msgCounts
