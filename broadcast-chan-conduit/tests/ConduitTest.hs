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

parallelSink :: Handler IO a -> [a] -> (a -> IO b) -> Int -> IO ()
parallelSink hnd inputs f n = runConduitRes $
    C.sourceList inputs .| parMapM_ handler n (liftIO . void . f)
  where
    handler = mapHandler liftIO hnd

sequentialFold :: Ord b => [a] -> (a -> IO b) -> IO (Set b)
sequentialFold inputs f = runConduitRes $
    C.sourceList inputs .| C.mapM (liftIO . f) .| C.foldMap S.singleton

parallelFold
    :: Ord b => Handler IO a -> [a] -> (a -> IO b) -> Int -> IO (Set b)
parallelFold hnd inputs f n = runConduitRes $
    C.sourceList inputs
        .| parMapM handler n (liftIO . f)
        .| C.foldMap S.singleton
  where
    handler = mapHandler liftIO hnd

main :: IO ()
main = runTests "conduit" $
    [ genStreamTests "sink" sequentialSink parallelSink
    , genStreamTests "fold" sequentialFold parallelFold
    ]
