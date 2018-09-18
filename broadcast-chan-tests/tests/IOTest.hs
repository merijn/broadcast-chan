{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
#if !MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>))
import Data.Foldable (Foldable(..))
#endif

import Control.Monad (void)
import Data.Foldable (forM_, foldlM)
import Data.Set (Set)
import qualified Data.Set as S

import BroadcastChan
import BroadcastChan.Test

sequentialSink :: Foldable f => f a -> (a -> IO b) -> IO ()
sequentialSink set f = forM_ set (void . f)

parallelSink
    :: Foldable f => Handler IO a -> f a -> (a -> IO b) -> Int -> IO ()
parallelSink hnd input f n =
  parMapM_ hnd n (void . f) input

sequentialFold :: (Foldable f, Ord b) => f a -> (a -> IO b) -> IO (Set b)
sequentialFold input f = foldlM foldFun S.empty input
  where
    foldFun bs a = (\b -> S.insert b bs) <$> f a

parallelFold
    :: (Foldable f, Ord b)
    => Handler IO a -> f a -> (a -> IO b) -> Int -> IO (Set b)
parallelFold hnd input f n =
  parFoldMap hnd n f foldFun S.empty input
  where
    foldFun :: Ord b => Set b -> b -> Set b
    foldFun s b = S.insert b s

parallelFoldM
    :: (Foldable f, Ord b)
    => Handler IO a -> f a -> (a -> IO b) -> Int -> IO (Set b)
parallelFoldM hnd input f n =
    parFoldMapM hnd n f foldFun S.empty input
  where
    foldFun :: (Ord b, Monad m) => Set b -> b -> m (Set b)
    foldFun !z b = return $ S.insert b z

main :: IO ()
main = runTests "parallel-io" $
    [ genStreamTests "sink" sequentialSink parallelSink
    , genStreamTests "fold" sequentialFold parallelFold
    , genStreamTests "foldM" sequentialFold parallelFoldM
    ]
