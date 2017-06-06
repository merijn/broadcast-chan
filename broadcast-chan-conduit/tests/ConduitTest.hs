import Control.Monad (void)
import Data.Set (Set)
import qualified Data.Set as S
import Data.Conduit
import qualified Data.Conduit.List as C

import BroadcastChan.Conduit
import BroadcastChan.Test

sequentialSink :: [a] -> (a -> IO b) -> IO ()
sequentialSink inputs f =
  runConduitRes $ C.sourceList inputs .| C.mapM_ (liftIO . void . f)

parallelSink :: [a] -> (a -> IO b) -> Int -> IO ()
parallelSink inputs f n = runConduitRes $
    C.sourceList inputs .| parMapM_ (Simple Terminate) n (void . f)

sequentialFold :: Ord b => [a] -> (a -> IO b) -> IO (Set b)
sequentialFold inputs f = runConduitRes $
    C.sourceList inputs .| C.mapM (liftIO . f) .| C.foldMap S.singleton

parallelFold :: Ord b => [a] -> (a -> IO b) -> Int -> IO (Set b)
parallelFold inputs f n = runConduitRes $
    C.sourceList inputs
        .| parMapM (Simple Terminate) n f
        .| C.foldMap S.singleton

main :: IO ()
main = runTests "conduit" $
    [ genStreamTests "sink" sequentialSink parallelSink
    , genStreamTests "fold" sequentialFold parallelFold
    ]
