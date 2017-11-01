import Control.Foldl (purely, set)
import Data.Set (Set)
import Pipes
import qualified Pipes.Prelude as P
import Pipes.Safe (runSafeT)

import BroadcastChan.Pipes
import BroadcastChan.Test

sequentialSink :: [a] -> (a -> IO b) -> IO ()
sequentialSink inputs f = runSafeT . runEffect $
    each inputs >-> P.mapM_ (liftIO . void. f)

parallelSink :: [a] -> (a -> IO b) -> Int -> IO ()
parallelSink inputs f n =
  runSafeT . runEffect $ parMapM_ (Simple Terminate) n (void . f) $ each inputs

sequentialFold :: Ord b => [a] -> (a -> IO b) -> IO (Set b)
sequentialFold inputs f = runSafeT $ purely P.fold set $
    each inputs >-> P.mapM (liftIO . f)

parallelFold :: Ord b => [a] -> (a -> IO b) -> Int -> IO (Set b)
parallelFold inputs f n =
  runSafeT . purely P.fold set . parMapM (Simple Terminate) n f $ each inputs

main :: IO ()
main = runTests "pipes" $
    [ genStreamTests "sink" sequentialSink parallelSink
    , genStreamTests "fold" sequentialFold parallelFold
    ]
