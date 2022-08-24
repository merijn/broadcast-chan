{-# LANGUAGE Safe #-}
-------------------------------------------------------------------------------
-- |
-- Module      :  BroadcastChan.Conduit
-- Copyright   :  (C) 2014-2022 Merijn Verstraaten
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Merijn Verstraaten <merijn@inconsistent.nl>
-- Stability   :  experimental
-- Portability :  haha
--
-- This module is identical to "BroadcastChan", but replaces the parallel
-- processing operations with functions for creating conduits and sinks that
-- process in parallel.
-------------------------------------------------------------------------------
module BroadcastChan.Conduit
    ( Action(..)
    , Handler(..)
    , parMapM
    , parMapM_
    -- * Re-exports from "BroadcastChan"
    -- ** Datatypes
    , BroadcastChan
    , Direction(..)
    , In
    , Out
    -- ** Construction
    , newBroadcastChan
    , newBChanListener
    -- ** Basic Operations
    , readBChan
    , writeBChan
    , closeBChan
    , isClosedBChan
    , getBChanContents
    -- ** Foldl combinators
    -- | Combinators for use with Tekmo's @foldl@ package.
    , foldBChan
    , foldBChanM
    ) where

import BroadcastChan hiding (parMapM_)
import BroadcastChan.Conduit.Internal
