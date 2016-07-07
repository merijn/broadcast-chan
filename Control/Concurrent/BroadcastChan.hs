{-# LANGUAGE DataKinds #-}
{-# LANGUAGE AutoDeriveTypeable #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE Safe #-}
-------------------------------------------------------------------------------
-- |
-- Module      :  Contro.Concurrent.BroadcastChan
-- Copyright   :  (C) 2014 Merijn Verstraaten
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Merijn Verstraaten <merijn@inconsistent.nl>
-- Stability   :  experimental
-- Portability :  haha
--
-- A variation of "Control.Concurrent.Chan" from base, which allows to the easy
-- creation of broadcast channels without the space-leaks that may arise from
-- using 'Control.Concurrent.Chan.dupChan'.
--
-- The 'Control.Concurrent.Chan.Chan' type from "Control.Concurrent.Chan"
-- consists of both a read and write end. This presents a problem when one
-- wants to have a broadcast channel that, at times, has zero listeners. To
-- write to a 'Control.Concurrent.Chan.Chan' there must always be a read end
-- and this read end will hold ALL messages alive until read.
--
-- The simple solution applied in this module is to separate read and write
-- ends. As a result, any messages written to the write end can be immediately
-- garbage collected if there are no active read ends, avoding space leaks.
-------------------------------------------------------------------------------
module Control.Concurrent.BroadcastChan
    ( BroadcastChan
    , In
    , Out
    , newBroadcastChan
    , writeBChan
    , readBChan
    , newBChanListener
    ) where

import Control.Concurrent.MVar
import Control.Exception (mask_)

data Direction = In | Out

-- | Alias for the 'In' type from the 'Direction' kind, allows users to write
-- the 'BroadcastChan In a' type without enabling DataKinds.
type In = 'In
-- | Alias for the 'Out' type from the 'Direction' kind, allows users to write
-- the 'BroadcastChan Out a' type without enabling DataKinds.
type Out = 'Out

-- | The abstract type representing the read or write end of a 'BroadcastChan'.
newtype BroadcastChan (d :: Direction) a = BChan (MVar (Stream a))
    deriving (Eq)

type Stream a = MVar (ChItem a)

data ChItem a = ChItem a {-# UNPACK #-} !(Stream a)

-- | Creates a new 'BroadcastChan' write end.
newBroadcastChan :: IO (BroadcastChan In a)
newBroadcastChan = do
   hole  <- newEmptyMVar
   writeVar <- newMVar hole
   return (BChan writeVar)

-- | Write a value to write end of a 'BroadcastChan'. Any messages written
-- while there are no live read ends can be immediately garbage collected, thus
-- avoiding space leaks.
writeBChan :: BroadcastChan In a -> a -> IO ()
writeBChan (BChan writeVar) val = do
  new_hole <- newEmptyMVar
  mask_ $ do
    old_hole <- takeMVar writeVar
    putMVar old_hole (ChItem val new_hole)
    putMVar writeVar new_hole

-- | Read the next value from the read end of a 'BroadcastChan'.
readBChan :: BroadcastChan Out a -> IO a
readBChan (BChan readVar) = do
  modifyMVarMasked readVar $ \read_end -> do -- Note [modifyMVarMasked]
    (ChItem val new_read_end) <- readMVar read_end
        -- Use readMVar here, not takeMVar,
        -- else dupBroadcastChan doesn't work
    return (new_read_end, val)

-- Note [modifyMVarMasked]
-- This prevents a theoretical deadlock if an asynchronous exception
-- happens during the readMVar while the MVar is empty.  In that case
-- the read_end MVar will be left empty, and subsequent readers will
-- deadlock.  Using modifyMVarMasked prevents this.  The deadlock can
-- be reproduced, but only by expanding readMVar and inserting an
-- artificial yield between its takeMVar and putMVar operations.

-- | Create a new read end for a 'BroadcastChan'. Will receive all messages
-- written to the channel's write end after the read end's creation.
newBChanListener :: BroadcastChan In a -> IO (BroadcastChan Out a)
newBChanListener (BChan writeVar) = do
   hole       <- readMVar writeVar
   newReadVar <- newMVar hole
   return (BChan newReadVar)
