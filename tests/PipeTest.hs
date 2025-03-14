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

parallelSink :: Handler IO a -> [a] -> (a -> IO b) -> Int -> IO ()
parallelSink hnd inputs f n =
  runSafeT . runEffect $ parMapM_ handler n (void . f) $ each inputs
  where
    handler = mapHandler liftIO hnd

sequentialFold :: Ord b => [a] -> (a -> IO b) -> IO (Set b)
sequentialFold inputs f = runSafeT $ purely P.fold set $
    each inputs >-> P.mapM (liftIO . f)

parallelFold
    :: Ord b => Handler IO a -> [a] -> (a -> IO b) -> Int -> IO (Set b)
parallelFold hnd inputs f n =
  runSafeT . purely P.fold set . parMapM handler n f $ each inputs
  where
    handler = mapHandler liftIO hnd

main :: IO ()
main = runTests "pipes" $
    [ genStreamTests "sink" sequentialSink parallelSink
    , genStreamTests "fold" sequentialFold parallelFold
    ]
