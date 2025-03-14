{-# LANGUAGE CPP #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE ScopedTypeVariables #-}
module BroadcastChan.Conduit.Internal (parMapM, parMapM_) where

import Control.Exception (SomeException)
import Control.Monad ((>=>))
import Control.Monad.Trans.Resource (MonadResource)
import qualified Control.Monad.Trans.Resource as Resource
import qualified Control.Monad.Trans.Resource.Internal as ResourceI
import Control.Monad.Trans.Class (lift)
import Control.Monad.IO.Unlift (MonadUnliftIO, UnliftIO(..), askUnliftIO)
import Data.Acquire (ReleaseType(..), allocateAcquire, mkAcquireType)
import Data.Conduit (ConduitM, (.|), awaitForever, yield)
import qualified Data.Conduit.List as C
import Data.Foldable (traverse_)
import Data.Void (Void)

import BroadcastChan.Extra (BracketOnError(..), Handler, ThreadBracket(..))
import qualified BroadcastChan.Extra as Extra

releaseWithException :: SomeException -> ReleaseType
#if !MIN_VERSION_resourcet(1,3,0)
releaseWithException _ = ReleaseException
#else
releaseWithException exc = ReleaseExceptionWith exc
#endif

bracketOnError :: MonadResource m => IO a -> (a -> IO ()) -> m r -> m r
bracketOnError alloc clean work =
    allocateAcquire (mkAcquireType alloc cleanup) >>= const work
  where
#if !MIN_VERSION_resourcet(1,3,0)
    cleanup x ReleaseException = clean x
#else
    cleanup x (ReleaseExceptionWith _) = clean x
#endif
    cleanup _ _ = return ()

-- | Create a conduit that processes inputs in parallel.
--
-- This function does __NOT__ guarantee that input elements are processed or
-- output in a deterministic order!
--
-- @since 0.2.0
parMapM
    :: (MonadResource m, MonadUnliftIO m)
    => Handler m a
    -- ^ Exception handler
    -> Int
    -- ^ Number of parallel threads to use
    -> (a -> m b)
    -- ^ Function to run in parallel
    -> ConduitM a b m ()
parMapM hnd threads workFun = do
    UnliftIO runInIO <- lift askUnliftIO

    resourceState <- Resource.liftResourceT Resource.getInternalState

    let threadBracket = ThreadBracket
            { setupFork = ResourceI.stateAlloc resourceState
            , cleanupFork = ResourceI.stateCleanup ReleaseNormal resourceState
            , cleanupForkError = \exc ->
                ResourceI.stateCleanup (releaseWithException exc) resourceState
            }

    Bracket{allocate,cleanup,action} <- Extra.runParallelWith
        threadBracket
        (Left yield)
        (Extra.mapHandler runInIO hnd)
        threads
        (runInIO . workFun)
        body

    bracketOnError allocate cleanup action
  where
    body :: Monad m => (a -> m ()) -> (a -> m (Maybe b)) -> ConduitM a b m ()
    body buffer process = do
        C.isolate threads .| C.mapM_ buffer
        awaitForever $ lift . process >=> traverse_ yield

-- | Create a conduit sink that consumes inputs in parallel.
--
-- This function does __NOT__ guarantee that input elements are processed or
-- output in a deterministic order!
--
-- @since 0.2.0
parMapM_
    :: (MonadResource m, MonadUnliftIO m)
    => Handler m a
    -- ^ Exception handler
    -> Int
    -- ^ Number of parallel threads to use
    -> (a -> m ())
    -- ^ Function to run in parallel
    -> ConduitM a Void m ()
parMapM_ hnd threads workFun = do
    UnliftIO runInIO <- lift askUnliftIO

    resourceState <- Resource.liftResourceT Resource.getInternalState

    let threadBracket = ThreadBracket
            { setupFork = ResourceI.stateAlloc resourceState
            , cleanupFork = ResourceI.stateCleanup ReleaseNormal resourceState
            , cleanupForkError = \exc ->
                ResourceI.stateCleanup (releaseWithException exc) resourceState
            }

    Bracket{allocate,cleanup,action} <- Extra.runParallelWith_
        threadBracket
        (Extra.mapHandler runInIO hnd)
        threads
        (runInIO . workFun)
        C.mapM_

    bracketOnError allocate cleanup action
