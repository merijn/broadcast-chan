{-# LANGUAGE ScopedTypeVariables #-}
module BroadcastChan.Conduit (parMapM, parMapM_, module BroadcastChan) where

import Control.Monad.Trans.Resource (MonadResource)
import Data.Acquire
    (ReleaseType(ReleaseException), allocateAcquire, mkAcquireType)
import Data.Conduit
import qualified Data.Conduit.List as C
import Data.Void (Void)

import BroadcastChan hiding (parMapM_)
import BroadcastChan.Utils (runParallel, runParallel_)

bracketOnError :: MonadResource m => IO a -> (a -> IO ()) -> (a -> m r) -> m r
bracketOnError alloc clean work =
    allocateAcquire (mkAcquireType alloc cleanup) >>= work . snd
  where
    cleanup x ReleaseException = clean x
    cleanup _ _ = return ()

parMapM
    :: forall a b m
     . MonadResource m
    => Handler a
    -> Int
    -> (a -> IO b)
    -> ConduitM a b m ()
parMapM hnd threads = runParallel bracketOnError body (Left yield) hnd threads
  where
    body :: (a -> m ()) -> (a -> m b) -> ConduitM a b m ()
    body buffer process = do
        C.isolate threads .| C.mapM_ buffer
        C.mapM process

parMapM_
    :: MonadResource m
    => Handler a
    -> Int
    -> (a -> IO ())
    -> ConduitM a Void m ()
parMapM_ = runParallel_ bracketOnError C.mapM_
