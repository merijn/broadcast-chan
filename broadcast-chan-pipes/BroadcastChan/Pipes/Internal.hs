{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE Safe #-}
{-# LANGUAGE ScopedTypeVariables #-}
module BroadcastChan.Pipes.Internal (parMapM, parMapM_) where

import Control.Monad ((>=>), replicateM)
import Data.Foldable (traverse_)
import Pipes
import qualified Pipes.Prelude as P
import Pipes.Safe (MonadSafe)
import qualified Pipes.Safe as Safe

import BroadcastChan.Extra
    (BracketOnError(..), Handler, runParallel, runParallel_)

bracketOnError :: MonadSafe m => IO a -> (a -> IO b) -> m c -> m c
bracketOnError alloc clean =
  Safe.bracketOnError (liftIO alloc) (liftIO . clean) . const

-- | Create a producer that processes its inputs in parallel.
--
-- This function does *NOT* guarantee that input elements are processed or
-- output in a deterministic order!
parMapM
    :: forall a b m
     . MonadSafe m
    => Handler IO a
    -- ^ Exception handler
    -> Int
    -- ^ Number of parallel threads to use
    -> (a -> IO b)
    -- ^ Function to run in parallel
    -> Producer a m ()
    -- ^ Input producer
    -> Producer b m ()
parMapM hndl i f prod = do
    Bracket{allocate,cleanup,action} <- runParallel (Left yield) hndl i f body
    bracketOnError allocate cleanup action
  where
    body :: (a -> m ()) -> (a -> m (Maybe b)) -> Producer b m ()
    body buffer process = prod >-> work
      where
        work :: Pipe a b m ()
        work = do
            replicateM i (await >>= lift . buffer)
            for cat $ lift . process >=> traverse_ yield

-- | Create an Effect that processes its inputs in parallel.
--
-- This function does *NOT* guarantee that input elements are processed or
-- output in a deterministic order!
parMapM_
    :: MonadSafe m
    => Handler IO a
    -- ^ Exception handler
    -> Int
    -- ^ Number of parallel threads to use
    -> (a -> IO ())
    -- ^ Function to run in parallel
    -> Producer a m r
    -- ^ Input producer
    -> Effect m r
parMapM_ hndl i f prod = do
    Bracket{allocate,cleanup,action} <- runParallel_ hndl i f workProd
    bracketOnError allocate cleanup action
  where
    workProd buffer = prod >-> P.mapM_ buffer
