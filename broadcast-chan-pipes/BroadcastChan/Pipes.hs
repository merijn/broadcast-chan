{-# LANGUAGE Safe #-}
-------------------------------------------------------------------------------
-- |
-- Module      :  BroadcastChan.Pipes
-- Copyright   :  (C) 2014-2018 Merijn Verstraaten
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Merijn Verstraaten <merijn@inconsistent.nl>
-- Stability   :  experimental
-- Portability :  haha
--
-- This module is identical to "BroadcastChan", but replaces
-- @BroadcastChan.@'BroadcastChan.parMapM_' with 'parMapM' and 'parMapM_' which
-- create a parallel processing producer and effect, respectively.
-------------------------------------------------------------------------------
module BroadcastChan.Pipes
    ( parMapM
    , parMapM_
    -- * Re-exports from "BroadcastChan"
    , module BroadcastChan
    ) where

import BroadcastChan hiding (parMapM_)
import BroadcastChan.Pipes.Internal
