{-# LANGUAGE Safe #-}
-------------------------------------------------------------------------------
-- |
-- Module      :  BroadcastChan.Prelude
-- Copyright   :  (C) 2014-2021 Merijn Verstraaten
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Merijn Verstraaten <merijn@inconsistent.nl>
-- Stability   :  experimental
-- Portability :  haha
--
-- This module contains convenience functions that clash with names in
-- "Prelude" and is intended to be imported qualified.
-------------------------------------------------------------------------------
module BroadcastChan.Prelude
    ( forM_
    , mapM_
    ) where

import Prelude hiding (mapM_)
import Control.Monad.IO.Unlift (MonadIO(..))

import BroadcastChan

-- | 'mapM_' with it's arguments flipped.
forM_ :: MonadIO m => BroadcastChan Out a -> (a -> m b) -> m ()
forM_ = flip mapM_

-- | Map a monadic function over the elements of a 'BroadcastChan', ignoring
-- the results.
mapM_ :: MonadIO m => (a -> m b) -> BroadcastChan Out a -> m ()
mapM_ f ch = do
    result <- liftIO $ readBChan ch
    case result of
        Nothing -> return ()
        Just x -> f x >> mapM_ f ch
