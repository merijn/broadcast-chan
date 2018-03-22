{-# LANGUAGE Safe #-}
-------------------------------------------------------------------------------
-- |
-- Module      :  BroadcastChan.Prelude
-- Copyright   :  (C) 2014-2018 Merijn Verstraaten
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Merijn Verstraaten <merijn@inconsistent.nl>
-- Stability   :  experimental
-- Portability :  haha
--
-------------------------------------------------------------------------------
module BroadcastChan.Prelude
    ( forM_
    , mapM_
    ) where

import Prelude hiding (mapM_)
import Control.Monad.IO.Class (MonadIO(..))

import BroadcastChan

forM_ :: MonadIO m => BroadcastChan Out a -> (a -> m b) -> m ()
forM_ = flip mapM_

mapM_ :: MonadIO m => (a -> m b) -> BroadcastChan Out a -> m ()
mapM_ f ch = do
    result <- liftIO $ readBChan ch
    case result of
        Nothing -> return ()
        Just x -> f x >> mapM_ f ch
