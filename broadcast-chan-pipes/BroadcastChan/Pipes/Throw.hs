{-# LANGUAGE Safe #-}
-------------------------------------------------------------------------------
-- |
-- Module      :  BroadcastChan.Pipes.Throw
-- Copyright   :  (C) 2014-2018 Merijn Verstraaten
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Merijn Verstraaten <merijn@inconsistent.nl>
-- Stability   :  experimental
-- Portability :  haha
--
-- This module is identical to "BroadcastChan.Throw", but replaces
-- @BroadcastChan.Throw.@'BroadcastChan.Throw.parMapM_' with 'parMapM' and
-- 'parMapM_' which create a parallel processing producer and effect,
-- respectively.
-------------------------------------------------------------------------------
module BroadcastChan.Pipes.Throw
    ( parMapM
    , parMapM_
    , module BroadcastChan.Throw
    ) where

import BroadcastChan.Throw hiding (parMapM_)
import BroadcastChan.Pipes.Internal
