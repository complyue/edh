
module Language.Edh.Batteries.Console where

import           Prelude
import           Debug.Trace

import           GHC.Conc                       ( unsafeIOToSTM )

import           Control.Applicative
import           Control.Monad.Reader
import           Control.Concurrent
import           Control.Concurrent.STM

import           System.Clock

import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import qualified Data.List.NonEmpty            as NE
import qualified Data.HashMap.Strict           as Map

import           Text.Megaparsec

import           Data.Lossless.Decimal          ( decimalToInteger )

import           Language.Edh.Control
import           Language.Edh.Details.RtTypes
import           Language.Edh.Details.Evaluate
import           Language.Edh.Details.Utils


-- | operator (<|)
loggingProc :: EdhIntrinsicOp
loggingProc !lhExpr !rhExpr !exit = do
  !pgs <- ask
  let !ctx = edh'context pgs
      parseSpec :: EdhValue -> Maybe (Int, StmtSrc)
      parseSpec = \case
        EdhDecimal !level ->
          (, contextStmt ctx) . fromInteger <$> decimalToInteger level
        EdhPair (EdhDecimal !level) (EdhDecimal !unwind) ->
          liftA2 (,) (fromInteger <$> decimalToInteger level)
            $   scopeCaller
            .   contextFrame ctx
            .   fromInteger
            <$> decimalToInteger unwind
        _ -> Nothing
  evalExpr lhExpr $ \(OriginalValue !lhVal _ _) ->
    case parseSpec $ edhDeCaseClose lhVal of
      Just (logLevel, StmtSrc (srcPos, _)) -> if logLevel < 0
        -- as the log queue is a TBQueue per se, log msgs from a failing STM
        -- transaction has no way to go into the queue then get logged, but the
        -- failing cases are especially in need of diagnostics, so negative log
        -- level number is used to instruct a debug trace.
        then contEdhSTM $ do
          th <- unsafeIOToSTM myThreadId
          let !tracePrefix =
                " 🐞 " <> show th <> " 👉 " <> sourcePosPretty srcPos <> " ❗ "
          runEdhProc pgs $ evalExpr rhExpr $ \(OriginalValue !rhVal _ _) ->
            case edhDeCaseClose rhVal of
              EdhString !logStr ->
                trace (tracePrefix ++ T.unpack logStr) $ exitEdhProc exit nil
              _ -> edhValueRepr rhVal $ \(OriginalValue !rhRepr _ _) ->
                case rhRepr of
                  EdhString !logStr ->
                    trace (tracePrefix ++ T.unpack logStr)
                      $ exitEdhProc exit nil
                  _ ->
                    trace (tracePrefix ++ show rhRepr) $ exitEdhProc exit nil
        else contEdhSTM $ do
          let console      = worldConsole $ contextWorld ctx
              !conLogLevel = consoleLogLevel console
              !logger      = consoleLogger console
          if logLevel < conLogLevel
            then -- drop log msg without even eval it
                 exitEdhSTM pgs exit nil
            else
              runEdhProc pgs $ evalExpr rhExpr $ \(OriginalValue !rhV _ _) -> do
                let !rhVal  = edhDeCaseClose rhV
                    !srcLoc = if conLogLevel <= 20
                      then -- with source location info
                           Just $ sourcePosPretty srcPos
                      else -- no source location info
                           Nothing
                contEdhSTM $ case rhVal of
                  EdhArgsPack !apk -> do
                    logger logLevel srcLoc apk
                    exitEdhSTM pgs exit nil
                  _ -> do
                    logger logLevel srcLoc $ ArgsPack [rhVal] compactDictEmpty
                    exitEdhSTM pgs exit nil
      _ -> throwEdh EvalError $ "Invalid log target: " <> T.pack (show lhVal)


-- | host method console.exit(***apk)
--
-- this just throws a 'ProgramHalt', godforbid no one recover from it.
conExitProc :: EdhProcedure
conExitProc !apk _ = ask >>= \pgs -> -- cross check with 'createEdhWorld'
  contEdhSTM $ _getEdhErrClass pgs (AttrByName "ProgramHalt") >>= \ec ->
    runEdhProc pgs $ createEdhObject ec apk $ \(OriginalValue !exv _ _) ->
      edhThrow exv


-- | The default Edh command prompts
-- ps1 is for single line, ps2 for multi-line
defaultEdhPS1, defaultEdhPS2 :: Text
defaultEdhPS1 = "Đ: "
defaultEdhPS2 = "Đ| "

-- | host method console.readSource(ps1="(db)Đ: ", ps2="(db)Đ| ")
conReadSourceProc :: EdhProcedure
conReadSourceProc !apk !exit = ask >>= \pgs ->
  case parseArgsPack (defaultEdhPS1, defaultEdhPS2) argsParser apk of
    Left  err        -> throwEdh UsageError err
    Right (ps1, ps2) -> contEdhSTM $ do
      let !ioQ = consoleIO $ worldConsole $ contextWorld $ edh'context pgs
      cmdIn <- newEmptyTMVar
      writeTBQueue ioQ $ ConsoleIn cmdIn ps1 ps2
      edhPerformSTM pgs (readTMVar cmdIn)
        $ \(EdhInput !name !lineNo !lines_) -> case name of
            "" -> exitEdhProc exit $ EdhString $ T.unlines lines_
            _ ->
              exitEdhProc exit
                $ EdhPair
                    (EdhPair (EdhString name) (EdhDecimal $ fromIntegral lineNo)
                    )
                $ EdhString
                $ T.unlines lines_
 where
  argsParser =
    ArgsPackParser
        [ \arg (_, ps2') -> case arg of
          EdhString ps1s -> Right (ps1s, ps2')
          _              -> Left "Invalid ps1"
        , \arg (ps1', _) -> case arg of
          EdhString ps2s -> Right (ps1', ps2s)
          _              -> Left "Invalid ps2"
        ]
      $ Map.fromList
          [ ( "ps1"
            , \arg (_, ps2') -> case arg of
              EdhString ps1s -> Right (ps1s, ps2')
              _              -> Left "Invalid ps1"
            )
          , ( "ps2"
            , \arg (ps1', _) -> case arg of
              EdhString ps2s -> Right (ps1', ps2s)
              _              -> Left "Invalid ps2"
            )
          ]

-- | host method console.readCommand(ps1="Đ: ", ps2="Đ| ", inScopeOf=None)
conReadCommandProc :: EdhProcedure
conReadCommandProc !apk !exit = ask >>= \pgs ->
  case parseArgsPack (defaultEdhPS1, defaultEdhPS2, Nothing) argsParser apk of
    Left  err                   -> throwEdh UsageError err
    Right (ps1, ps2, inScopeOf) -> contEdhSTM $ do
      let ctx  = edh'context pgs
          !ioQ = consoleIO $ worldConsole $ contextWorld $ edh'context pgs
      -- mind to inherit this host proc's exception handler anyway
      cmdScope <- case inScopeOf of
        Just !so -> isScopeWrapper ctx so >>= \case
          True -> return $ (wrappedScopeOf so)
            { exceptionHandler = exceptionHandler $ contextScope ctx
            }
          False -> return $ (contextScope ctx)
           -- eval cmd source in the specified object's (probably a module)
           -- context scope
            { scopeEntity = objEntity so
            , thisObject  = so
            , thatObject  = so
            , scopeProc   = objClass so
            , scopeCaller = StmtSrc
                              ( SourcePos { sourceName   = "<console-cmd>"
                                          , sourceLine   = mkPos 1
                                          , sourceColumn = mkPos 1
                                          }
                              , VoidStmt
                              )
            }
        _ -> case NE.tail $ callStack ctx of
          -- eval cmd source with caller's this/that, and lexical context,
          -- while the entity is already the same as caller's
          callerScope : _ -> return $ (contextScope ctx)
            { thisObject  = thisObject callerScope
            , thatObject  = thatObject callerScope
            , scopeProc   = scopeProc callerScope
            , scopeCaller = scopeCaller callerScope
            }
          _ -> return $ contextScope ctx
      let !pgsCmd = pgs
            { edh'context = ctx
                              { callStack        = cmdScope
                                                     NE.:| NE.tail (callStack ctx)
                              , contextExporting = False
                              }
            }
      cmdIn <- newEmptyTMVar
      writeTBQueue ioQ $ ConsoleIn cmdIn ps1 ps2
      edhPerformSTM pgs (readTMVar cmdIn)
        $ \(EdhInput !name !lineNo !lines_) -> local (const pgsCmd) $ evalEdh'
            (if T.null name then "<console>" else T.unpack name)
            lineNo
            (T.unlines lines_)
            exit
 where
  argsParser =
    ArgsPackParser
        [ \arg (_, ps2', so) -> case arg of
          EdhString ps1s -> Right (ps1s, ps2', so)
          _              -> Left "Invalid ps1"
        , \arg (ps1', _, so) -> case arg of
          EdhString ps2s -> Right (ps1', ps2s, so)
          _              -> Left "Invalid ps2"
        ]
      $ Map.fromList
          [ ( "ps1"
            , \arg (_, ps2', so) -> case arg of
              EdhString ps1s -> Right (ps1s, ps2', so)
              _              -> Left "Invalid ps1"
            )
          , ( "ps2"
            , \arg (ps1', _, so) -> case arg of
              EdhString ps2s -> Right (ps1', ps2s, so)
              _              -> Left "Invalid ps2"
            )
          , ( "inScopeOf"
            , \arg (ps1, ps2, _) -> case arg of
              EdhObject so -> Right (ps1, ps2, Just so)
              _            -> Left "Invalid inScopeOf object"
            )
          ]


-- | host method console.print(*args, **kwargs)
conPrintProc :: EdhProcedure
conPrintProc (ArgsPack !args !kwargs) !exit = ask >>= \pgs -> contEdhSTM $ do
  let !ioQ = consoleIO $ worldConsole $ contextWorld $ edh'context pgs
      printVS :: [EdhValue] -> [(AttrKey, EdhValue)] -> STM ()
      printVS [] []              = exitEdhSTM pgs exit nil
      printVS [] ((k, v) : rest) = case v of
        EdhString !s -> do
          writeTBQueue ioQ
            $  ConsoleOut
            $  "  "
            <> T.pack (show k)
            <> "="
            <> s
            <> "\n"
          printVS [] rest
        _ -> runEdhProc pgs $ edhValueRepr v $ \(OriginalValue !vr _ _) ->
          case vr of
            EdhString !s -> contEdhSTM $ do
              writeTBQueue ioQ
                $  ConsoleOut
                $  "  "
                <> T.pack (show k)
                <> "="
                <> s
                <> "\n"
              printVS [] rest
            _ -> error "bug"
      printVS (v : rest) !kvs = case v of
        EdhString !s -> do
          writeTBQueue ioQ $ ConsoleOut $ s <> "\n"
          printVS rest kvs
        _ -> runEdhProc pgs $ edhValueRepr v $ \(OriginalValue !vr _ _) ->
          case vr of
            EdhString !s -> contEdhSTM $ do
              writeTBQueue ioQ $ ConsoleOut $ s <> "\n"
              printVS rest kvs
            _ -> error "bug"
  printVS args $ compactDictToList kwargs


conNowProc :: EdhProcedure
conNowProc _ !exit = do
  pgs <- ask
  contEdhSTM $ do
    nanos <- (toNanoSecs <$>) $ unsafeIOToSTM $ getTime Realtime
    exitEdhSTM pgs exit (EdhDecimal $ fromInteger nanos)


data PeriodicArgs = PeriodicArgs {
    periodic'interval :: !Int
  , periodic'wait1st :: !Bool
  }

timelyNotify
  :: EdhProgState -> PeriodicArgs -> EdhGenrCaller -> EdhProcExit -> STM ()
timelyNotify !pgs (PeriodicArgs !delayMicros !wait1st) (!pgs', !iter'cb) !exit
  = if wait1st
    then edhPerformIO pgs (threadDelay delayMicros) $ \() -> contEdhSTM notifOne
    else notifOne
 where
  notifOne = do
    nanos <- (toNanoSecs <$>) $ unsafeIOToSTM $ getTime Realtime
    runEdhProc pgs' $ iter'cb (EdhDecimal $ fromInteger nanos) $ \case
      Left (pgsThrower, exv) ->
        edhThrowSTM pgsThrower { edh'context = edh'context pgs } exv
      Right EdhBreak         -> exitEdhSTM pgs exit nil
      Right (EdhReturn !rtn) -> exitEdhSTM pgs exit rtn
      _ ->
        edhPerformIO pgs (threadDelay delayMicros) $ \() -> contEdhSTM notifOne

-- | host generator console.everyMicros(n, wait1st=true) - with fixed interval
conEveryMicrosProc :: EdhProcedure
conEveryMicrosProc !apk !exit = ask >>= \pgs ->
  case generatorCaller $ edh'context pgs of
    Nothing -> throwEdh EvalError "Can only be called as generator"
    Just genr'caller ->
      case parseArgsPack (PeriodicArgs 1 True) parsePeriodicArgs apk of
        Right !pargs -> contEdhSTM $ timelyNotify pgs pargs genr'caller exit
        Left  !err   -> throwEdh UsageError err

-- | host generator console.everyMillis(n, wait1st=true) - with fixed interval
conEveryMillisProc :: EdhProcedure
conEveryMillisProc !apk !exit = ask >>= \pgs ->
  case generatorCaller $ edh'context pgs of
    Nothing -> throwEdh EvalError "Can only be called as generator"
    Just genr'caller ->
      case parseArgsPack (PeriodicArgs 1 True) parsePeriodicArgs apk of
        Right !pargs -> contEdhSTM $ timelyNotify
          pgs
          pargs { periodic'interval = 1000 * periodic'interval pargs }
          genr'caller
          exit
        Left !err -> throwEdh UsageError err

-- | host generator console.everySeconds(n, wait1st=true) - with fixed interval
conEverySecondsProc :: EdhProcedure
conEverySecondsProc !apk !exit = ask >>= \pgs ->
  case generatorCaller $ edh'context pgs of
    Nothing -> throwEdh EvalError "Can only be called as generator"
    Just genr'caller ->
      case parseArgsPack (PeriodicArgs 1 True) parsePeriodicArgs apk of
        Right !pargs -> contEdhSTM $ timelyNotify
          pgs
          pargs { periodic'interval = 1000000 * periodic'interval pargs }
          genr'caller
          exit
        Left !err -> throwEdh UsageError err

parsePeriodicArgs :: ArgsPackParser PeriodicArgs
parsePeriodicArgs =
  ArgsPackParser
      [ \arg pargs -> case arg of
          EdhDecimal !d -> case decimalToInteger d of
            Just !i -> Right $ pargs { periodic'interval = fromIntegral i }
            _ -> Left $ "Invalid interval, expect an integer but: " <> T.pack
              (show arg)
          _ -> Left $ "Invalid interval, expect an integer but: " <> T.pack
            (show arg)
      ]
    $ Map.fromList
        [ ( "wait1st"
          , \arg pargs -> case arg of
            EdhBool !w -> Right pargs { periodic'wait1st = w }
            _ -> Left $ "Invalid wait1st, expect true or false but: " <> T.pack
              (show arg)
          )
        ]

