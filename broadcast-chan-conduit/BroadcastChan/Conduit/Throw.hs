{-# LANGUAGE Safe #-}
-------------------------------------------------------------------------------
-- |
-- Module      :  BroadcastChan.Conduit.Throw
-- Copyright   :  (C) 2014-2018 Merijn Verstraaten
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Merijn Verstraaten <merijn@inconsistent.nl>
-- Stability   :  experimental
-- Portability :  haha
--
-- This module is identical to "BroadcastChan.Throw", but replaces
-- @BroadcastChan.Throw.@'BroadcastChan.Throw.parMapM_' with 'parMapM' and
-- 'parMapM_' which create a parallel processing conduit and sink,
-- respectively.
-------------------------------------------------------------------------------
module BroadcastChan.Conduit.Throw
    ( parMapM
    , parMapM_
    -- * Re-exports from "BroadcastChan.Throw"
    , module BroadcastChan.Throw
    ) where

import BroadcastChan.Throw hiding (parMapM_)
import BroadcastChan.Conduit.Internal
