{-# LANGUAGE Safe #-}
-------------------------------------------------------------------------------
-- |
-- Module      :  BroadcastChan.Conduit
-- Copyright   :  (C) 2014-2018 Merijn Verstraaten
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Merijn Verstraaten <merijn@inconsistent.nl>
-- Stability   :  experimental
-- Portability :  haha
--
-- This module is identical to "BroadcastChan", but replaces
-- @BroadcastChan.@'BroadcastChan.parMapM_' with 'parMapM' and 'parMapM_' which
-- create a parallel processing conduit and sink, respectively.
-------------------------------------------------------------------------------
module BroadcastChan.Conduit
    ( parMapM
    , parMapM_
    -- * Re-exports from "BroadcastChan"
    , module BroadcastChan
    ) where

import BroadcastChan hiding (parMapM_)
import BroadcastChan.Conduit.Internal
