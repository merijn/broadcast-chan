{-# LANGUAGE ScopedTypeVariables #-}
module BroadcastChan.Pipes (module BroadcastChan, parMapM, parMapM_) where

import Control.Monad (replicateM)
import Pipes
import qualified Pipes.Prelude as P
import Pipes.Safe (MonadSafe, bracketOnError)

import BroadcastChan hiding (parMapM_)
import BroadcastChan.Utils (runParallel, runParallel_)

parMapM
    :: forall a b m
     . MonadSafe m
    => Handler a
    -> Int
    -> (a -> IO b)
    -> Producer a m ()
    -> Producer b m ()
parMapM hndl i f prod = runParallel bracketOnError body (Left yield) hndl i f
  where
    body :: (a -> m ()) -> (a -> m b) -> Producer b m ()
    body buffer process = prod >-> work
      where
        work :: Pipe a b m ()
        work = do
            replicateM i (await >>= lift . buffer)
            P.mapM process

parMapM_
    :: MonadSafe m
    => Handler a
    -> Int
    -> (a -> IO ())
    -> Producer a m r
    -> Effect m r
parMapM_ hndl i f prod = runParallel_ bracketOnError work hndl i f
  where
    work buffer = prod >-> P.mapM_ buffer
