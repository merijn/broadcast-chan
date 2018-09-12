{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ScopedTypeVariables #-}
-------------------------------------------------------------------------------
-- |
-- Module      :  BroadcastChan
-- Copyright   :  (C) 2014-2018 Merijn Verstraaten
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Merijn Verstraaten <merijn@inconsistent.nl>
-- Stability   :  experimental
-- Portability :  haha
--
-- Module containing testing helpers shared across all broadcast-chan packages.
-------------------------------------------------------------------------------
module BroadcastChan.Test
    ( (@?)
    , expect
    , doNothing
    , doPrint
    , genStreamTests
    , runTests
    , MonadIO(..)
    , module Test.Tasty
    , module Test.Tasty.HUnit
    ) where

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>),(<*>))
#endif
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (wait, withAsync)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Monad.IO.Class (MonadIO(liftIO))
import Control.Exception (Exception, try)
import Data.Bifunctor (second)
import Data.List (sort)
import Data.Map (Map)
import qualified Data.Map as M
import Data.Monoid ((<>), mconcat)
import Data.Proxy (Proxy(Proxy))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Tagged (Tagged, untag)
import Data.Typeable (Typeable)
import Options.Applicative (switch, long, help)
import System.Clock
    (Clock(Monotonic), TimeSpec, diffTimeSpec, getTime, toNanoSecs)
#if !MIN_VERSION_base(4,7,0)
import System.Posix.Env (setEnv)
#else
import System.Environment (setEnv)
#endif
import System.IO (Handle, SeekMode(AbsoluteSeek), hPrint, hSeek)
import System.IO.Temp (withSystemTempFile)
import Test.Tasty
import Test.Tasty.Golden.Advanced (goldenTest)
import Test.Tasty.HUnit hiding ((@?))
import qualified Test.Tasty.HUnit as HUnit
import Test.Tasty.Options
import Test.Tasty.Travis

import ParamTree

infix 0 @?
(@?) :: IO Bool -> String -> Assertion
(@?) = (HUnit.@?)

-- | Test which fails if the expected exception is not thrown by the 'IO'
-- action.
expect :: (Eq e, Exception e) => e -> IO () -> Assertion
expect err act = do
    result <- try act
    case result of
        Left e | e == err -> return ()
               | otherwise -> assertFailure $
                                "Expected: " ++ show err ++ "\nGot: " ++ show e
        Right _ -> assertFailure $ "Expected exception, got success."

-- | Pauses a number of microseconds before returning its input.
doNothing :: Int -> a -> IO a
doNothing threadPause x = do
    threadDelay threadPause
    return x

-- | Print a value, then return it.
doPrint :: Show a => Handle -> a -> IO a
doPrint hnd x = do
    hPrint hnd x
    return x

fromTimeSpec :: Fractional n => TimeSpec -> n
fromTimeSpec = fromIntegral . toNanoSecs

speedupTest
    :: forall r . (Eq r, Show r)
    => IO (TVar (Map ([Int], Int) (MVar (r, Double))))
    -> ([Int] -> (Int -> IO Int) -> IO r)
    -> ([Int] -> (Int -> IO Int) -> Int -> IO r)
    -> Int
    -> [Int]
    -> Int
    -> String
    -> TestTree
speedupTest getCache seqSink parSink n inputs pause name = testCase name $ do
    withAsync cachedSequential $ \seqAsync ->
      withAsync (timed $ parSink inputs testFun n) $ \parAsync -> do
        (seqResult, seqTime) <- wait seqAsync
        (parResult, parTime) <- wait parAsync
        seqResult @=? parResult
        let lowerBound :: Double
            lowerBound = seqTime / (fromIntegral n + 1)

            upperBound :: Double
            upperBound = seqTime / (fromIntegral n - 1)

            errorMsg :: String
            errorMsg = mconcat
                [ "Parallel time should be 1/"
                , show n
                , "th of sequential time!\n"
                , "Actual time was 1/"
                , show (round $ seqTime / parTime :: Int)
                , "th (", show (seqTime/parTime), ")"
                ]
        assertBool errorMsg $ lowerBound < parTime && parTime < upperBound
  where
    testFun :: Int -> IO Int
    testFun = doNothing pause

    timed :: IO a -> IO (a, Double)
    timed = fmap (\(x, t) -> (x, fromTimeSpec t)) . withTime

    cachedSequential :: IO (r, Double)
    cachedSequential = do
        mvar <- newEmptyMVar
        cacheTVar <- getCache
        result <- atomically $ do
            cacheMap <- readTVar cacheTVar
            let (oldVal, newMap) = M.insertLookupWithKey
                    (\_ _ v -> v)
                    (inputs, pause)
                    mvar
                    cacheMap
            writeTVar cacheTVar newMap
            return oldVal

        case result of
            Just var -> readMVar var
            Nothing -> do
                timed (seqSink inputs testFun) >>= putMVar mvar
                readMVar mvar

outputTest
    :: forall r . (Eq r, Show r)
    => ([Int] -> (Int -> IO Int) -> IO r)
    -> ([Int] -> (Int -> IO Int) -> Int -> IO r)
    -> Int
    -> [Int]
    -> String
    -> TestTree
outputTest seqSink parSink threads inputs label =
    nonDeterministicGolden label seqTest parTest diff (const $ return ())
  where
    nonDeterministicGolden name x y =
      goldenTest name (normalise x) (normalise y)

    normalise :: MonadIO m => IO (a, Text) -> m (a, Text)
    normalise = liftIO . fmap (second (T.strip . T.unlines . sort . T.lines))

    diff :: (r, Text) -> (r, Text) -> IO (Maybe String)
    diff (seqResult, seqOutput) (parResult, parOutput) =
        return $ resultDiff <> outputDiff
      where
        resultDiff :: Maybe String
        resultDiff
            | seqResult == parResult = Nothing
            | otherwise = Just "Results differ!\n"

        outputDiff :: Maybe String
        outputDiff
            | seqOutput == parOutput = Nothing
            | otherwise = Just . mconcat $
                [ "Outputs differ!\n"
                , "Expected:\n\"", T.unpack seqOutput, "\"\n\n"
                , "Got:\n\"", T.unpack parOutput, "\"\n"
                ]

    rewindAndRead :: Handle -> IO Text
    rewindAndRead hnd = do
        hSeek hnd AbsoluteSeek 0
        T.hGetContents hnd

    seqTest :: IO (r, Text)
    seqTest = withSystemTempFile "seq.out" $ \_ hndl ->
        (,) <$> seqSink inputs (doPrint hndl) <*> rewindAndRead hndl

    parTest :: IO (r, Text)
    parTest = withSystemTempFile "par.out" $ \_ hndl ->
        (,) <$> parSink inputs (doPrint hndl) threads <*> rewindAndRead hndl

newtype SlowTests = SlowTests Bool
  deriving (Eq, Ord, Typeable)

instance IsOption SlowTests where
  defaultValue = SlowTests False
  parseValue = fmap SlowTests . safeRead
  optionName = return "slow-tests"
  optionHelp = return "Run slow tests."
  optionCLParser =
    fmap SlowTests $
    switch
      (  long (untag (optionName :: Tagged SlowTests String))
      <> help (untag (optionHelp :: Tagged SlowTests String))
      )

-- | Takes a name, a sequential sink, and a parallel sink and generates tasty
-- tests from these.
--
-- The parallel and sequential sink should perform the same tasks so their
-- results can be compared to check correctness.
--
-- The sinks should take a list of input data, a function processing the data,
-- and return a result that can be compared for equality.
--
-- Furthermore the parallel sink should take a number indicating how many
-- concurrent consumers should be used.
genStreamTests
    :: (Eq r, Show r)
    => String -- ^ Name to group tests under
    -> ([Int] -> (Int -> IO Int) -> IO r) -- ^ Sequential sink
    -> ([Int] -> (Int -> IO Int) -> Int -> IO r) -- ^ Parallel sink
    -> TestTree
genStreamTests name f g = askOption $ \(SlowTests slow) ->
    withResource (newTVarIO M.empty) (const $ return ()) $ \getCache ->
    let
        testTree = growTree (Just "/") testGroup
        params
          | slow = simpleParam "threads" [1,2,5]
                 . derivedParam (enumFromTo 0) "inputs" [600]
          | otherwise = simpleParam "threads" [1,2,5]
                      . derivedParam (enumFromTo 0) "inputs" [300]
        pause = simpleParam "pause" [10^(5 :: Int)]

    in testGroup name
        [ testTree "output" (outputTest f g) params
        , testTree "speedup" (speedupTest getCache f g) $ params . pause
        ]

-- | Run a list of 'TestTree''s and group them under the specified name.
runTests :: String -> [TestTree] -> IO ()
runTests name tests = do
    setEnv "TASTY_NUM_THREADS" "100"
#if !MIN_VERSION_base(4,7,0)
        True
#endif
    travisTestReporter travisConfig ingredients $ testGroup name tests
  where
    ingredients = [ includingOptions [Option (Proxy :: Proxy SlowTests)] ]

    travisConfig = defaultConfig
      { travisFoldGroup = FoldMoreThan 1
      , travisSummaryWhen = SummaryAlways
      , travisTestOptions = setOption (SlowTests True)
      }

withTime :: IO a -> IO (a, TimeSpec)
withTime act = do
    start <- getTime Monotonic
    r <- act
    end <- getTime Monotonic
    return $ (r, diffTimeSpec start end)
