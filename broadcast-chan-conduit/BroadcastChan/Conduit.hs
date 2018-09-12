{-# LANGUAGE ScopedTypeVariables #-}
module BroadcastChan.Conduit (parMapM, parMapM_, module BroadcastChan) where

import Control.Monad.Trans.Resource (MonadResource)
import Data.Acquire
    (ReleaseType(ReleaseException), allocateAcquire, mkAcquireType)
import Data.Conduit
import Control.Monad.Trans.Class (lift)
import Control.Monad.IO.Unlift (MonadUnliftIO(askUnliftIO), UnliftIO(..))
import qualified Data.Conduit.List as C
import Data.Void (Void)

import BroadcastChan hiding (parMapM_)
import BroadcastChan.Utils (mapHandler, runParallel, runParallel_)

bracketOnError :: MonadResource m => IO a -> (a -> IO ()) -> m r -> m r
bracketOnError alloc clean work =
    allocateAcquire (mkAcquireType alloc cleanup) >>= const work
  where
    cleanup x ReleaseException = clean x
    cleanup _ _ = return ()

parMapM
    :: (MonadResource m, MonadUnliftIO m)
    => Handler m a
    -> Int
    -> (a -> m b)
    -> ConduitM a b m ()
parMapM hnd threads workFun = do
    UnliftIO runInIO <- lift askUnliftIO

    (alloc, clean, work) <- runParallel
        (Left yield)
        (mapHandler runInIO hnd)
        threads
        (runInIO . workFun)
        body

    bracketOnError alloc clean work
  where
    body :: Monad m => (a -> m ()) -> (a -> m b) -> ConduitM a b m ()
    body buffer process = do
        C.isolate threads .| C.mapM_ buffer
        C.mapM process

parMapM_
    :: (MonadResource m, MonadUnliftIO m)
    => Handler m a
    -> Int
    -> (a -> m ())
    -> ConduitM a Void m ()
parMapM_ hnd threads workFun = do
    UnliftIO runInIO <- lift askUnliftIO

    (alloc, clean, work) <- runParallel_
        (mapHandler runInIO hnd)
        threads
        (runInIO . workFun)
        C.mapM_

    bracketOnError alloc clean work
