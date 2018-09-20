{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE Trustworthy #-}
module BroadcastChan.Internal where

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative ((<*))
#endif
import Control.Concurrent.MVar
import Control.Exception (mask_)
import Control.Monad ((>=>))
import Control.Monad.IO.Unlift (MonadIO(..))
import System.IO.Unsafe (unsafeInterleaveIO)

#if !MIN_VERSION_base(4,6,0)
import Control.Exception (evaluate, onException)
#endif

-- | Used with DataKinds as phantom type indicating whether a 'BroadcastChan'
-- value is a read or write end.
data Direction = In  -- ^ Indicates a write 'BroadcastChan'
               | Out -- ^ Indicates a read 'BroadcastChan'

-- | Alias for the 'In' type from the 'Direction' kind, allows users to write
-- the @'BroadcastChan' 'In' a@ type without enabling @DataKinds@.
type In = 'In

-- | Alias for the 'Out' type from the 'Direction' kind, allows users to write
-- the @'BroadcastChan' 'Out' a@ type without enabling @DataKinds@.
type Out = 'Out

-- | The abstract type representing the read or write end of a 'BroadcastChan'.
newtype BroadcastChan (dir :: Direction) a = BChan (MVar (Stream a))
    deriving (Eq)

type Stream a = MVar (ChItem a)

data ChItem a = ChItem a {-# UNPACK #-} !(Stream a) | Closed

-- | Creates a new 'BroadcastChan' write end.
newBroadcastChan :: MonadIO m => m (BroadcastChan In a)
newBroadcastChan = liftIO $ do
   hole  <- newEmptyMVar
   writeVar <- newMVar hole
   return (BChan writeVar)

-- | Close a 'BroadcastChan', disallowing further writes. Returns 'True' if the
-- 'BroadcastChan' was closed. Returns 'False' if the 'BroadcastChan' was
-- __already__ closed.
closeBChan :: MonadIO m => BroadcastChan In a -> m Bool
closeBChan (BChan writeVar) = liftIO . mask_ $ do
    old_hole <- takeMVar writeVar
    -- old_hole is always empty unless the channel was already closed
    tryPutMVar old_hole Closed <* putMVar writeVar old_hole

-- | Check whether a 'BroadcastChan' is closed. 'True' meaning that future
-- read/write operations on the channel will always fail.
--
--  ['BroadcastChan' 'In':]:
--
--      @True@ indicates the channel is closed and writes will always fail.
--
--      __Beware of TOC-TOU races__: It is possible for a 'BroadcastChan' to be
--      closed by another thread. If multiple threads use the same channel
--      a 'closeBChan' from another thread can result in the channel being
--      closed right after 'isClosedBChan' returns.
--
--  ['BroadcastChan' 'Out':]:
--
--      @True@ indicates the channel is both closed and empty, meaning reads
--      will always fail.
isClosedBChan :: MonadIO m => BroadcastChan dir a -> m Bool
#if MIN_VERSION_base(4,7,0)
isClosedBChan (BChan mvar) = liftIO $ do
    old_hole <- readMVar mvar
    val <- tryReadMVar old_hole
#else
isClosedBChan (BChan mvar) = liftIO . mask_ $ do
    old_hole <- takeMVar mvar
    val <- tryTakeMVar old_hole
    case val of
        Just x -> putMVar old_hole x
        Nothing -> return ()
    putMVar mvar old_hole
#endif
    case val of
        Just Closed -> return True
        _ -> return False

-- | Write a value to write end of a 'BroadcastChan'. Any messages written
-- while there are no live read ends are dropped on the floor and can be
-- immediately garbage collected, thus avoiding space leaks.
--
-- The return value indicates whether the write succeeded, i.e., 'True' if the
-- message was written, 'False' is the channel is closed.
-- See @BroadcastChan.Throw.@'BroadcastChan.Throw.writeBChan' for an
-- exception throwing variant.
writeBChan :: MonadIO m => BroadcastChan In a -> a -> m Bool
writeBChan (BChan writeVar) val = liftIO $ do
  new_hole <- newEmptyMVar
  mask_ $ do
    old_hole <- takeMVar writeVar
    -- old_hole is only full if the channel was previously closed
    empty <- tryPutMVar old_hole (ChItem val new_hole)
    if empty
       then putMVar writeVar new_hole
       else putMVar writeVar old_hole
    return empty
{-# INLINE writeBChan #-}

-- | Read the next value from the read end of a 'BroadcastChan'. Returns
-- 'Nothing' if the 'BroadcastChan' is closed and empty.
-- See @BroadcastChan.Throw.@'BroadcastChan.Throw.readBChan' for an exception
-- throwing variant.
readBChan :: MonadIO m => BroadcastChan Out a -> m (Maybe a)
readBChan (BChan readVar) = liftIO $ do
  modifyMVarMasked readVar $ \read_end -> do -- Note [modifyMVarMasked]
    -- Use readMVar here, not takeMVar,
    -- else newBChanListener doesn't work
    result <- readMVar read_end
    case result of
        ChItem val new_read_end -> return (new_read_end, Just val)
        Closed -> return (read_end, Nothing)
{-# INLINE readBChan #-}

-- Note [modifyMVarMasked]
-- This prevents a theoretical deadlock if an asynchronous exception
-- happens during the readMVar while the MVar is empty.  In that case
-- the read_end MVar will be left empty, and subsequent readers will
-- deadlock.  Using modifyMVarMasked prevents this.  The deadlock can
-- be reproduced, but only by expanding readMVar and inserting an
-- artificial yield between its takeMVar and putMVar operations.

-- | Create a new read end for a 'BroadcastChan'.
--
--  ['BroadcastChan' 'In':]:
--
--      Will receive all messages written to the channel __after__ this read
--      end is created.
--
--  ['BroadcastChan' 'Out':]:
--
--      Will receive all currently unread messages and all future messages.
newBChanListener :: MonadIO m => BroadcastChan dir a -> m (BroadcastChan Out a)
newBChanListener (BChan mvar) = liftIO $ do
   hole       <- readMVar mvar
   newReadVar <- newMVar hole
   return (BChan newReadVar)

-- | Return a lazy list representing the messages written to the channel.
--
-- Uses 'unsafeInterleaveIO' to defer the IO operations.
--
--  ['BroadcastChan' 'In':]:
--
--      The list contains every message written to the channel after this 'IO'
--      action completes.
--
--  ['BroadcastChan' 'Out':]:
--
--      The list contains every currently unread message and all future
--      messages. It's safe to keep using the original channel in any thread.
--
--      Unlike 'Control.Concurrent.getChanContents' from "Control.Concurrent",
--      the list resulting from this function is __not__ affected by reads on
--      the input channel. Every message that is unread or written after the
--      'IO' action completes __will__ end up in the result list.
getBChanContents :: BroadcastChan dir a -> IO [a]
getBChanContents = newBChanListener >=> go
  where
    go ch = unsafeInterleaveIO $ do
        result <- readBChan ch
        case result of
            Nothing -> return []
            Just x -> do
                xs <- go ch
                return (x:xs)

-- | Strict fold of the 'BroadcastChan''s messages. Can be used with
-- "Control.Foldl" from Tekmo's foldl package:
--
-- @"Control.Foldl".'Control.Foldl.purely' 'foldBChan' :: 'MonadIO' m => 'Control.Foldl.Fold' a b -> 'BroadcastChan' 'In' a -> m (m b)@
foldBChan
    :: (MonadIO m, MonadIO n)
    => (x -> a -> x)
    -> x
    -> (x -> b)
    -> BroadcastChan In a
    -> n (m b)
foldBChan step begin done chan = do
    listen <- newBChanListener chan
    return $ go listen begin
  where
    go listen x = do
        x' <- readBChan listen
        case x' of
            Just x'' -> go listen $! step x x''
            Nothing -> return $! done x
{-# INLINABLE foldBChan #-}

-- | Strict, monadic fold of the 'BroadcastChan''s messages. Can be used with
-- "Control.Foldl" from Tekmo's foldl package:
--
-- @"Control.Foldl".'Control.Foldl.impurely' 'foldBChanM' :: 'MonadIO' m => 'FoldM' m a b -> 'BroadcastChan' 'In' a -> m (m b)
foldBChanM
    :: (MonadIO m, MonadIO n)
    => (x -> a -> m x)
    -> m x
    -> (x -> m b)
    -> BroadcastChan In a
    -> n (m b)
foldBChanM step begin done chan = do
    listen <- newBChanListener chan
    return $ do
        x0 <- begin
        go listen x0
  where
    go listen x = do
        x' <- readBChan listen
        case x' of
            Just x'' -> step x x'' >>= go listen
            Nothing -> done x
{-# INLINABLE foldBChanM #-}

#if !MIN_VERSION_base(4,6,0)
{-# INLINE modifyMVarMasked #-}
modifyMVarMasked :: MVar a -> (a -> IO (a,b)) -> IO b
modifyMVarMasked m io =
  mask_ $ do
    a      <- takeMVar m
    (a',b) <- (io a >>= evaluate) `onException` putMVar m a
    putMVar m a'
    return b
#endif
