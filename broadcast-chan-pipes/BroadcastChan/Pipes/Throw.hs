{-# LANGUAGE Safe #-}
-------------------------------------------------------------------------------
-- |
-- Module      :  BroadcastChan.Pipes.Throw
-- Copyright   :  (C) 2014-2020 Merijn Verstraaten
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Merijn Verstraaten <merijn@inconsistent.nl>
-- Stability   :  experimental
-- Portability :  haha
--
-- This module is identical to "BroadcastChan.Throw", but replaces the parallel
-- processing operations with functions for creating producers and effects that
-- process in parallel.
-------------------------------------------------------------------------------
module BroadcastChan.Pipes.Throw
    ( Action(..)
    , Handler(..)
    , parMapM
    , parMapM_
    -- * Re-exports from "BroadcastChan.Throw"
    -- ** Datatypes
    , BroadcastChan
    , Direction(..)
    , In
    , Out
    , BChanError(..)
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

import BroadcastChan.Throw hiding (parMapM_)
import BroadcastChan.Pipes.Internal
