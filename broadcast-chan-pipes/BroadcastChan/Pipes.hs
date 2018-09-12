{-# LANGUAGE ScopedTypeVariables #-}
module BroadcastChan.Pipes (module BroadcastChan, parMapM, parMapM_) where

import Control.Monad (replicateM)
import Pipes
import qualified Pipes.Prelude as P
import Pipes.Safe (MonadSafe)
import qualified Pipes.Safe as Safe

import BroadcastChan hiding (parMapM_)
import BroadcastChan.Utils (runParallel, runParallel_)

bracketOnError :: MonadSafe m => IO a -> (a -> IO b) -> m c -> m c
bracketOnError alloc clean =
  Safe.bracketOnError (liftIO alloc) (liftIO . clean) . const

parMapM
    :: forall a b m
     . MonadSafe m
    => Handler IO a
    -> Int
    -> (a -> IO b)
    -> Producer a m ()
    -> Producer b m ()
parMapM hndl i f prod = do
    (alloc, clean, work) <- runParallel (Left yield) hndl i f body
    bracketOnError alloc clean work
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
    => Handler IO a
    -> Int
    -> (a -> IO ())
    -> Producer a m r
    -> Effect m r
parMapM_ hndl i f prod = do
    (alloc, clean, work) <- runParallel_ hndl i f workProd
    bracketOnError alloc clean work
  where
    workProd buffer = prod >-> P.mapM_ buffer
