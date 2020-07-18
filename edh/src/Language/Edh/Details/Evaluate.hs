
module Language.Edh.Details.Evaluate where

import           Prelude
-- import           Debug.Trace

import           GHC.Conc                       ( unsafeIOToSTM )

import           Control.Exception
import           Control.Monad.Except
import           Control.Monad.Reader
import           Control.Monad.State.Strict
import           Control.Concurrent
import           Control.Concurrent.STM

import           Data.Unique
import           Data.Maybe
import           Data.Either
import qualified Data.ByteString               as B
import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import           Data.Text.Encoding
import           Data.Text.Encoding.Error
import qualified Data.HashMap.Strict           as Map
import           Data.List.NonEmpty             ( NonEmpty(..)
                                                , (<|)
                                                )
import qualified Data.List.NonEmpty            as NE
import           Data.Dynamic

import           Text.Megaparsec

import           Data.Lossless.Decimal         as D

import           Language.Edh.Control
import           Language.Edh.Parser
import           Language.Edh.Event

import           Language.Edh.Details.IOPD
import           Language.Edh.Details.RtTypes
import           Language.Edh.Details.CoreLang
import           Language.Edh.Details.PkgMan
import           Language.Edh.Details.Utils


-- | Fork a GHC thread to run the specified Edh proc concurrently
forkEdh :: EdhProgState -> EdhProc -> STM ()
forkEdh !pgs !p = writeTBQueue (edh'fork'queue pgs) (pgs, p)


-- | Fork a new Edh thread to run the specified event producer, but hold the 
-- production until current thread has later started consuming events from the
-- sink returned here.
launchEventProducer :: EdhProcExit -> EventSink -> EdhProc -> EdhProc
launchEventProducer !exit sink@(EventSink _ _ _ _ !subc) !producerProg = do
  pgsConsumer <- ask
  let !pgsLaunch = pgsConsumer { edh'in'tx = False }
  contEdhSTM $ do
    subcBefore <- readTVar subc
    void $ forkEdh pgsLaunch $ do
      pgsProducer <- ask
      contEdhSTM
        $ edhPerformSTM
            pgsProducer
            (do
              subcNow <- readTVar subc
              when (subcNow == subcBefore) retry
            )
        $ const producerProg
    exitEdhSTM pgsConsumer exit $ EdhSink sink


parseEdh :: EdhWorld -> String -> Text -> STM (Either ParserError [StmtSrc])
parseEdh !world !srcName !srcCode = parseEdh' world srcName 1 srcCode
parseEdh'
  :: EdhWorld -> String -> Int -> Text -> STM (Either ParserError [StmtSrc])
parseEdh' !world !srcName !lineNo !srcCode = do
  pd <- takeTMVar wops -- update 'worldOperators' atomically wrt parsing
  let ((_, pr), pd') = runState
        (runParserT'
          parseProgram
          State
            { stateInput       = srcCode
            , stateOffset      = 0
            , statePosState    = PosState
                                   { pstateInput      = srcCode
                                   , pstateOffset     = 0
                                   , pstateSourcePos  = SourcePos
                                                          { sourceName = srcName
                                                          , sourceLine = mkPos
                                                                           lineNo
                                                          , sourceColumn = mkPos 1
                                                          }
                                   , pstateTabWidth   = mkPos 2
                                   , pstateLinePrefix = ""
                                   }
            , stateParseErrors = []
            }
        )
        pd
  case pr of
    -- update operator precedence dict on success of parsing
    Right _ -> putTMVar wops pd'
    -- restore original precedence dict on failure of parsing
    _       -> putTMVar wops pd
  return pr
  where !wops = worldOperators world


evalEdh :: String -> Text -> EdhProcExit -> EdhProc
evalEdh !srcName !srcCode !exit = evalEdh' srcName 1 srcCode exit
evalEdh' :: String -> Int -> Text -> EdhProcExit -> EdhProc
evalEdh' !srcName !lineNo !srcCode !exit = do
  pgs <- ask
  let ctx   = edh'context pgs
      world = contextWorld ctx
  contEdhSTM $ parseEdh' world srcName lineNo srcCode >>= \case
    Left !err -> getEdhErrClass pgs ParseError >>= \ec ->
      runEdhProc pgs
        $ createEdhObject
            ec
            (ArgsPack [EdhString $ T.pack $ errorBundlePretty err] odEmpty)
        $ \(OriginalValue !exv _ _) -> edhThrow exv
    Right !stmts -> runEdhProc pgs $ evalBlock stmts exit


deParen :: Expr -> Expr
deParen x = case x of
  ParenExpr x' -> deParen x'
  _            -> x

deApk :: ArgsPack -> ArgsPack
deApk (ArgsPack [EdhArgsPack !apk] !kwargs) | odNull kwargs = apk
deApk apk = apk

evalStmt :: StmtSrc -> EdhProcExit -> EdhProc
evalStmt ss@(StmtSrc (_sp, !stmt)) !exit = ask >>= \pgs ->
  local (const pgs { edh'context = (edh'context pgs) { contextStmt = ss } })
    $ evalStmt' stmt
    $ \rtn -> local (const pgs) $ exitEdhProc' exit rtn

evalCaseBlock :: Expr -> EdhProcExit -> EdhProc
evalCaseBlock !expr !exit = case expr of
  -- case-of with a block is normal
  BlockExpr stmts' -> evalBlock stmts' exit
  -- single branch case is some special
  _                -> evalExpr expr $ \(OriginalValue !val _ _) -> case val of
    -- the only branch did match
    (EdhCaseClose !v) -> exitEdhProc exit $ edhDeCaseClose v
    -- the only branch didn't match
    EdhCaseOther      -> exitEdhProc exit nil
    -- yield should have been handled by 'evalExpr'
    (EdhYield _)      -> throwEdh EvalError "bug yield reached block"
    -- ctrl to be propagated outwards, as this is the only stmt, no need to
    -- be specifically written out
    -- EdhFallthrough    -> exitEdhProc exit EdhFallthrough
    -- EdhBreak          -> exitEdhProc exit EdhBreak
    -- EdhContinue       -> exitEdhProc exit EdhContinue
    -- (EdhReturn !v)    -> exitEdhProc exit (EdhReturn v)
    -- other vanilla result, propagate as is
    _                 -> exitEdhProc exit val

evalBlock :: [StmtSrc] -> EdhProcExit -> EdhProc
evalBlock []    !exit = exitEdhProc exit nil
evalBlock [!ss] !exit = evalStmt ss $ \(OriginalValue !val _ _) -> case val of
  -- last branch did match
  (EdhCaseClose !v) -> exitEdhProc exit $ edhDeCaseClose v
  -- yield should have been handled by 'evalExpr'
  (EdhYield     _ ) -> throwEdh EvalError "bug yield reached block"
  -- ctrl to be propagated outwards, as this is the last stmt, no need to
  -- be specifically written out
  -- EdhCaseOther      -> exitEdhProc exit EdhCaseOther
  -- EdhFallthrough    -> exitEdhProc exit EdhFallthrough
  -- EdhRethrow        -> exitEdhProc exit EdhRethrow
  -- EdhBreak          -> exitEdhProc exit EdhBreak
  -- EdhContinue       -> exitEdhProc exit EdhContinue
  -- (EdhReturn !v)    -> exitEdhProc exit (EdhReturn v)
  -- other vanilla result, propagate as is
  _                 -> exitEdhProc exit val
evalBlock (ss : rest) !exit = evalStmt ss $ \(OriginalValue !val _ _) ->
  case val of
    -- a branch matched, finish this block
    (EdhCaseClose !v) -> exitEdhProc exit $ edhDeCaseClose v
    -- should continue to next branch (or stmt)
    EdhCaseOther      -> evalBlock rest exit
    -- should fallthrough to next branch (or stmt)
    EdhFallthrough    -> evalBlock rest exit
    -- yield should have been handled by 'evalExpr'
    (EdhYield _)      -> throwEdh EvalError "bug yield reached block"
    -- ctrl to interrupt this block, and to be propagated outwards
    EdhRethrow        -> exitEdhProc exit EdhRethrow
    EdhBreak          -> exitEdhProc exit EdhBreak
    EdhContinue       -> exitEdhProc exit EdhContinue
    (EdhReturn !v)    -> exitEdhProc exit (EdhReturn v)
    -- other vanilla result, continue this block
    _                 -> evalBlock rest exit


-- | a left-to-right expr list eval'er, returning a tuple
evalExprs :: [Expr] -> EdhProcExit -> EdhProc
-- here 'EdhArgsPack' is used for intermediate tag,
-- not intend to return an actual apk value
evalExprs []       !exit = exitEdhProc exit (EdhArgsPack $ ArgsPack [] odEmpty)
evalExprs (x : xs) !exit = evalExpr x $ \(OriginalValue !val _ _) ->
  evalExprs xs $ \(OriginalValue !tv _ _) -> case tv of
    EdhArgsPack (ArgsPack !l _) ->
      exitEdhProc exit (EdhArgsPack $ ArgsPack (edhDeCaseClose val : l) odEmpty)
    _ -> error "bug"


evalStmt' :: Stmt -> EdhProcExit -> EdhProc
evalStmt' !stmt !exit = do
  !pgs <- ask
  let !ctx   = edh'context pgs
      !scope = contextScope ctx
      this   = thisObject scope
  case stmt of

    ExprStmt !expr -> evalExpr expr $ \result -> exitEdhProc' exit result

    LetStmt !argsRcvr !argsSndr ->
      -- ensure args sending and receiving happens within a same tx
      -- for atomicity of the let statement
      local (const pgs { edh'in'tx = True }) $ packEdhArgs argsSndr $ \ !apk ->
        recvEdhArgs ctx argsRcvr (deApk apk) $ \um -> contEdhSTM $ do
          if not (contextEffDefining ctx)
            then -- normal multi-assignment
                 updateEntityAttrs pgs (scopeEntity scope) $ odToList um
            else do -- define effectful artifacts by multi-assignment
              let !effd = [ (attrKeyValue k, v) | (k, v) <- odToList um ]
              lookupEntityAttr pgs
                               (scopeEntity scope)
                               (AttrByName edhEffectsMagicName)
                >>= \case
                      EdhDict (Dict _ !effDS) -> iopdUpdate effd effDS
                      _                       -> do
                        d <- createEdhDict effd
                        changeEntityAttr pgs
                                         (scopeEntity scope)
                                         (AttrByName edhEffectsMagicName)
                                         d
          when (contextExporting ctx) $ do -- do export what's assigned
            let !impd = [ (attrKeyValue k, v) | (k, v) <- odToList um ]
            lookupEntityAttr pgs
                             (objEntity this)
                             (AttrByName edhExportsMagicName)
              >>= \case
                    EdhDict (Dict _ !thisExpDS) -> iopdUpdate impd thisExpDS
                    _                           -> do -- todo warn if of wrong type
                      d <- createEdhDict impd
                      changeEntityAttr pgs
                                       (objEntity this)
                                       (AttrByName edhExportsMagicName)
                                       d
          exitEdhSTM pgs exit nil
          -- let statement evaluates to nil always, with previous tx
          -- state restored

    BreakStmt        -> exitEdhProc exit EdhBreak
    ContinueStmt     -> exitEdhProc exit EdhContinue
    FallthroughStmt  -> exitEdhProc exit EdhFallthrough
    RethrowStmt      -> exitEdhProc exit EdhRethrow

    ReturnStmt !expr -> evalExpr expr $ \(OriginalValue !v2r _ _) ->
      case edhDeCaseClose v2r of
        val@EdhReturn{} -> exitEdhProc exit (EdhReturn val)
          -- actually when a generator procedure checks the result of its `yield`
          -- for the case of early return from the do block, if it wants to
          -- cooperate, double return is the only option
          -- throwEdh UsageError "you don't double return"
        !val            -> exitEdhProc exit (EdhReturn val)


    AtoIsoStmt !expr ->
      contEdhSTM
        $ runEdhProc pgs { edh'in'tx = True } -- ensure in'tx state
        $ evalExpr expr
        $ \(OriginalValue !val _ _) -> -- restore original tx state
            contEdhSTM $ exitEdhSTM pgs exit $ edhDeCaseClose val


    GoStmt !expr -> do
      let doFork :: EdhProgState -> (Context -> Context) -> EdhProc -> STM ()
          doFork pgs' !ctxMod !prog = do
            forkEdh
              pgs'
                { edh'context = ctxMod ctx { contextMatch       = true
                                           , contextPure        = False
                                           , contextExporting   = False
                                           , contextEffDefining = False
                                           }
                }
              prog
            exitEdhSTM pgs exit nil
      case expr of

        CaseExpr !tgtExpr !branchesExpr ->
          evalExpr tgtExpr $ \(OriginalValue !val _ _) ->
            contEdhSTM
              $ doFork pgs (\ctx' -> ctx' { contextMatch = edhDeCaseClose val })
              $ evalCaseBlock branchesExpr edhEndOfProc

        (CallExpr !procExpr !argsSndr) ->
          contEdhSTM
            $ resolveEdhCallee pgs procExpr
            $ \(OriginalValue !callee'val _ !callee'that, scopeMod) ->
                edhMakeCall pgs callee'val callee'that argsSndr scopeMod
                  $ \mkCall -> doFork pgs id (mkCall edhEndOfProc)

        (ForExpr !argsRcvr !iterExpr !doExpr) ->
          contEdhSTM
            $ edhForLoop pgs argsRcvr iterExpr doExpr (const $ return ())
            $ \runLoop -> doFork pgs id (runLoop edhEndOfProc)

        _ -> contEdhSTM $ doFork pgs id $ evalExpr expr edhEndOfProc


    DeferStmt !expr -> do
      let schedDefered
            :: EdhProgState -> (Context -> Context) -> EdhProc -> STM ()
          schedDefered !pgs' !ctxMod !prog = do
            modifyTVar'
              (edh'defers pgs)
              (( pgs'
                 { edh'context = ctxMod $ (edh'context pgs')
                                   { contextMatch       = true
                                   , contextPure        = False
                                   , contextExporting   = False
                                   , contextEffDefining = False
                                   }
                 }
               , prog
               ) :
              )
            exitEdhSTM pgs exit nil
      case expr of

        CaseExpr !tgtExpr !branchesExpr ->
          evalExpr tgtExpr $ \(OriginalValue !val _ _) ->
            contEdhSTM
              $ schedDefered
                  pgs
                  (\ctx' -> ctx' { contextMatch = edhDeCaseClose val })
              $ evalCaseBlock branchesExpr edhEndOfProc

        (CallExpr !procExpr !argsSndr) ->
          contEdhSTM
            $ resolveEdhCallee pgs procExpr
            $ \(OriginalValue !callee'val _ !callee'that, scopeMod) ->
                edhMakeCall pgs callee'val callee'that argsSndr scopeMod
                  $ \mkCall -> schedDefered pgs id (mkCall edhEndOfProc)

        (ForExpr !argsRcvr !iterExpr !doExpr) ->
          contEdhSTM
            $ edhForLoop pgs argsRcvr iterExpr doExpr (const $ return ())
            $ \runLoop -> schedDefered pgs id (runLoop edhEndOfProc)

        _ -> contEdhSTM $ schedDefered pgs id $ evalExpr expr edhEndOfProc


    PerceiveStmt !sinkExpr !bodyExpr ->
      evalExpr sinkExpr $ \(OriginalValue !sinkVal _ _) ->
        case edhUltimate sinkVal of
          (EdhSink sink) -> contEdhSTM $ do
            (perceiverChan, _) <- subscribeEvents sink
            modifyTVar'
              (edh'perceivers pgs)
              (( perceiverChan
               , pgs
                 { edh'context = ctx { contextExporting   = False
                                     , contextEffDefining = False
                                     }
                 }
               , bodyExpr
               ) :
              )
            exitEdhSTM pgs exit nil
          _ ->
            throwEdh EvalError
              $  "Can only perceive from an event sink, not a "
              <> T.pack (edhTypeNameOf sinkVal)
              <> ": "
              <> T.pack (show sinkVal)


    ThrowStmt excExpr -> evalExpr excExpr
      $ \(OriginalValue !exv _ _) -> edhThrow $ edhDeCaseClose exv


    WhileStmt !cndExpr !bodyStmt -> do
      let doWhile :: EdhProc
          doWhile = evalExpr cndExpr $ \(OriginalValue !cndVal _ _) ->
            case edhDeCaseClose cndVal of
              (EdhBool True) ->
                evalStmt bodyStmt $ \(OriginalValue !blkVal _ _) ->
                  case edhDeCaseClose blkVal of
                  -- early stop of procedure
                    rtnVal@EdhReturn{} -> exitEdhProc exit rtnVal
                    -- break while loop
                    EdhBreak           -> exitEdhProc exit nil
                    -- continue while loop
                    _                  -> doWhile
              (EdhBool False) -> exitEdhProc exit nil
              EdhNil          -> exitEdhProc exit nil
              _ ->
                throwEdh EvalError
                  $  "Invalid condition value for while: "
                  <> T.pack (edhTypeNameOf cndVal)
                  <> ": "
                  <> T.pack (show cndVal)
      doWhile

    ExtendsStmt !superExpr ->
      evalExpr superExpr $ \(OriginalValue !superVal _ _) ->
        case edhDeCaseClose superVal of
          (EdhObject !superObj) -> contEdhSTM $ do
            let
              !magicSpell = AttrByName "<-^"
              noMagic :: EdhProc
              noMagic =
                contEdhSTM $ lookupEdhObjAttr pgs superObj magicSpell >>= \case
                  EdhNil    -> exitEdhSTM pgs exit nil
                  !magicMth -> withMagicMethod magicMth
              withMagicMethod :: EdhValue -> STM ()
              withMagicMethod magicMth = case magicMth of
                EdhNil              -> exitEdhSTM pgs exit nil
                EdhMethod !mth'proc -> do
                  scopeObj <- mkScopeWrapper ctx $ objectScope ctx this
                  runEdhProc pgs
                    $ callEdhMethod this
                                    mth'proc
                                    (ArgsPack [EdhObject scopeObj] odEmpty)
                                    id
                    $ \_ -> contEdhSTM $ exitEdhSTM pgs exit nil
                _ ->
                  throwEdhSTM pgs EvalError
                    $  "Invalid magic (<-^) method type: "
                    <> T.pack (edhTypeNameOf magicMth)
            modifyTVar' (objSupers this) (superObj :)
            runEdhProc pgs
              $ getEdhAttrWSM edhMetaMagicSpell superObj magicSpell noMagic
              $ \(OriginalValue !magicMth _ _) ->
                  contEdhSTM $ withMagicMethod magicMth
          _ ->
            throwEdh EvalError
              $  "Can only extends an object, not "
              <> T.pack (edhTypeNameOf superVal)
              <> ": "
              <> T.pack (show superVal)

    EffectStmt !effs ->
      local
          (const pgs
            { edh'context = (edh'context pgs) { contextEffDefining = True }
            }
          )
        $ evalExpr effs
        $ \rtn -> local (const pgs) $ exitEdhProc' exit rtn

    VoidStmt -> exitEdhProc exit nil

    -- _ -> throwEdh EvalError $ "Eval not yet impl for: " <> T.pack (show stmt)


importInto :: Entity -> ArgsReceiver -> Expr -> EdhProcExit -> EdhProc
importInto !tgtEnt !argsRcvr !srcExpr !exit = case srcExpr of
  LitExpr (StringLiteral !importSpec) ->
    -- import from specified path
    importEdhModule' tgtEnt argsRcvr importSpec exit
  _ -> evalExpr srcExpr $ \(OriginalValue !srcVal _ _) ->
    case edhDeCaseClose srcVal of
      EdhString !importSpec ->
        -- import from dynamic path
        importEdhModule' tgtEnt argsRcvr importSpec exit
      EdhObject !fromObj ->
        -- import from an object
        importFromObject tgtEnt argsRcvr fromObj exit
      EdhArgsPack !fromApk ->
        -- import from an argument pack
        importFromApk tgtEnt argsRcvr fromApk exit
      _ ->
        -- todo support more sources of import ?
        throwEdh EvalError
          $  "Don't know how to import from a "
          <> T.pack (edhTypeNameOf srcVal)
          <> ": "
          <> T.pack (show srcVal)


importFromApk :: Entity -> ArgsReceiver -> ArgsPack -> EdhProcExit -> EdhProc
importFromApk !tgtEnt !argsRcvr !fromApk !exit = do
  pgs <- ask
  let !ctx = edh'context pgs
  recvEdhArgs ctx argsRcvr fromApk $ \em -> contEdhSTM $ do
    if not (contextEffDefining ctx)
      then -- normal import
           updateEntityAttrs pgs tgtEnt $ odToList em
      else do -- importing effects
        let !effd = [ (attrKeyValue k, v) | (k, v) <- odToList em ]
        lookupEntityAttr pgs tgtEnt (AttrByName edhEffectsMagicName) >>= \case
          EdhDict (Dict _ !effDS) -> iopdUpdate effd effDS
          _                       -> do -- todo warn if of wrong type
            d <- createEdhDict effd
            changeEntityAttr pgs tgtEnt (AttrByName edhEffectsMagicName) d
    when (contextExporting ctx) $ do -- do export what's imported
      let !impd = [ (attrKeyValue k, v) | (k, v) <- odToList em ]
      lookupEntityAttr pgs tgtEnt (AttrByName edhExportsMagicName) >>= \case
        EdhDict (Dict _ !thisExpDS) -> iopdUpdate impd thisExpDS
        _                           -> do -- todo warn if of wrong type
          d <- createEdhDict impd
          changeEntityAttr pgs tgtEnt (AttrByName edhExportsMagicName) d
    exitEdhSTM pgs exit $ EdhArgsPack fromApk

edhExportsMagicName :: Text
edhExportsMagicName = "__exports__"

importFromObject :: Entity -> ArgsReceiver -> Object -> EdhProcExit -> EdhProc
importFromObject !tgtEnt !argsRcvr !fromObj !exit = do
  pgs <- ask
  let withExps :: [(AttrKey, EdhValue)] -> STM ()
      withExps !exps =
        runEdhProc pgs
          $ importFromApk tgtEnt argsRcvr (ArgsPack [] $ odFromList exps)
          $ \_ -> exitEdhProc exit $ EdhObject fromObj
  contEdhSTM
    $ lookupEntityAttr pgs (objEntity fromObj) (AttrByName edhExportsMagicName)
    >>= \case
          EdhNil -> -- nothing exported at all
            withExps []
          EdhDict (Dict _ !fromExpDS) -> iopdToList fromExpDS >>= \ !expl ->
            withExps $ catMaybes
              [ case k of
                  EdhString !expKey -> Just (AttrByName expKey, v)
                  EdhSymbol !expSym -> Just (AttrBySym expSym, v)
                  _                 -> Nothing -- todo warn about this
              | (k, v) <- expl
              ]
          badExplVal ->
            throwEdhSTM pgs UsageError $ "bad __exports__ type: " <> T.pack
              (edhTypeNameOf badExplVal)

importEdhModule' :: Entity -> ArgsReceiver -> Text -> EdhProcExit -> EdhProc
importEdhModule' !tgtEnt !argsRcvr !importSpec !exit =
  importEdhModule importSpec $ \(OriginalValue !moduVal _ _) -> case moduVal of
    EdhObject !modu -> importFromObject tgtEnt argsRcvr modu exit
    _               -> error "bug"

importEdhModule :: Text -> EdhProcExit -> EdhProc
importEdhModule !impSpec !exit = do
  pgs <- ask
  let
    !ctx   = edh'context pgs
    !world = contextWorld ctx
    !scope = contextScope ctx
    locateModuInFS :: ((FilePath, FilePath) -> STM ()) -> STM ()
    locateModuInFS !exit' =
      lookupEdhCtxAttr pgs scope (AttrByName "__name__") >>= \case
        EdhString !moduName ->
          lookupEdhCtxAttr pgs scope (AttrByName "__file__") >>= \case
            EdhString !fromModuPath -> do
              let !importPath = case normalizedSpec of
      -- special case for `import * '.'`, 2 possible use cases:
      --
      --  *) from an entry module (i.e. __main__.edh), to import artifacts
      --     from its respective persistent module
      --
      --  *) from a persistent module, to re-populate the module scope with
      --     its own exports (i.e. the dict __exports__ in its scope), in
      --     case the module scope possibly altered after initialization
                    "." -> T.unpack moduName
                    _   -> T.unpack normalizedSpec
              (nomPath, moduFile) <- unsafeIOToSTM $ locateEdhModule
                (edhPkgPathFrom $ T.unpack fromModuPath)
                importPath
              exit' (nomPath, moduFile)
            _ -> error "bug: no valid `__file__` in context"
        _ -> error "bug: no valid `__name__` in context"
    importFromFS :: STM ()
    importFromFS =
      flip
          catchSTM
          (\(e :: EdhError) -> case e of
            EdhError !et !msg _ -> throwEdhSTM pgs et msg
            _                   -> throwSTM e
          )
        $ locateModuInFS
        $ \(nomPath, moduFile) -> do
            let !moduId = T.pack nomPath
            moduMap' <- takeTMVar (worldModules world)
            case Map.lookup moduId moduMap' of
              Just !moduSlot -> do
                -- put back immediately
                putTMVar (worldModules world) moduMap'
                -- blocking wait the target module loaded
                edhPerformSTM pgs (readTMVar moduSlot) $ \case
                  -- TODO GHC should be able to detect cyclic imports as 
                  --      deadlock, better to report that more friendly,
                  --      and more importantly, to prevent the crash.
                  EdhNamedValue _ !importError ->
                    -- the first importer failed loading it,
                    -- replicate the error in this thread
                    edhThrow importError
                  !modu -> exitEdhProc exit modu
              Nothing -> do -- we are the first importer
                -- allocate an empty slot
                moduSlot <- newEmptyTMVar
                -- put it for global visibility
                putTMVar (worldModules world)
                  $ Map.insert moduId moduSlot moduMap'
                -- try load the module
                runEdhProc pgs
                  $ edhCatch (loadModule moduSlot moduId moduFile) exit
                  $ \_ !rethrow -> ask >>= \pgsPassOn ->
                      case contextMatch $ edh'context pgsPassOn of
                        EdhNil      -> rethrow -- no error occurred
                        importError -> contEdhSTM $ do
                          void $ tryPutTMVar moduSlot $ EdhNamedValue
                            "importError"
                            importError
                          -- cleanup on loading error
                          moduMap'' <- takeTMVar (worldModules world)
                          case Map.lookup moduId moduMap'' of
                            Nothing -> putTMVar (worldModules world) moduMap''
                            Just moduSlot' -> if moduSlot' == moduSlot
                              then putTMVar (worldModules world)
                                $ Map.delete moduId moduMap''
                              else putTMVar (worldModules world) moduMap''
                          runEdhProc pgsPassOn rethrow
  if edh'in'tx pgs
    then throwEdh UsageError "You don't import from within a transaction"
    else contEdhSTM $ do
      moduMap <- readTMVar (worldModules world)
      case Map.lookup normalizedSpec moduMap of
        -- attempt the import specification as direct module id first
        Just !moduSlot -> readTMVar moduSlot >>= \case
          -- import error has been encountered, propagate the error
          EdhNamedValue _ !importError -> runEdhProc pgs $ edhThrow importError
          -- module already imported, got it as is
          !modu                        -> exitEdhSTM pgs exit modu
        -- resolving to `.edh` source files from local filesystem
        Nothing -> importFromFS
 where
  normalizedSpec = normalizeImpSpec impSpec
  normalizeImpSpec :: Text -> Text
  normalizeImpSpec = withoutLeadingSlash . withoutTrailingSlash
  withoutLeadingSlash spec = fromMaybe spec $ T.stripPrefix "/" spec
  withoutTrailingSlash spec = fromMaybe spec $ T.stripSuffix "/" spec

loadModule :: TMVar EdhValue -> ModuleId -> FilePath -> EdhProcExit -> EdhProc
loadModule !moduSlot !moduId !moduFile !exit = ask >>= \pgsImporter ->
  if edh'in'tx pgsImporter
    then throwEdh UsageError "You don't load a module from within a transaction"
    else contEdhSTM $ do
      let !importerCtx = edh'context pgsImporter
          !world       = contextWorld importerCtx
      fileContent <-
        unsafeIOToSTM
        $   streamDecodeUtf8With lenientDecode
        <$> B.readFile moduFile
      case fileContent of
        Some !moduSource _ _ -> do
          modu <- createEdhModule' world moduId moduFile
          let !loadScope = objectScope importerCtx modu
              !loadCtx   = importerCtx
                { callStack          = loadScope <| callStack importerCtx
                , contextExporting   = False
                , contextEffDefining = False
                }
              !pgsLoad = pgsImporter { edh'context = loadCtx }
          runEdhProc pgsLoad $ evalEdh moduFile moduSource $ \_ ->
            contEdhSTM $ do
              -- arm the successfully loaded module
              void $ tryPutTMVar moduSlot $ EdhObject modu
              -- switch back to module importer's scope and continue
              exitEdhSTM pgsImporter exit $ EdhObject modu

createEdhModule' :: EdhWorld -> ModuleId -> String -> STM Object
createEdhModule' !world !moduId !srcName = do
  -- prepare the module meta data
  !moduEntity <- createHashEntity =<< iopdFromList
    [ (AttrByName "__name__", EdhString moduId)
    , (AttrByName "__file__", EdhString $ T.pack srcName)
    , (AttrByName "__repr__", EdhString $ "module:" <> moduId)
    ]
  !moduSupers    <- newTVar []
  !moduClassUniq <- unsafeIOToSTM newUnique
  return Object
    { objEntity = moduEntity
    , objClass  = ProcDefi
      { procedure'uniq = moduClassUniq
      , procedure'name = AttrByName $ "module:" <> moduId
      , procedure'lexi = Just $ worldScope world
      , procedure'decl = ProcDecl
                           { procedure'addr = NamedAttr $ "module:" <> moduId
                           , procedure'args = PackReceiver []
                           , procedure'body = Left $ StmtSrc
                                                ( SourcePos
                                                  { sourceName   = srcName
                                                  , sourceLine   = mkPos 1
                                                  , sourceColumn = mkPos 1
                                                  }
                                                , VoidStmt
                                                )
                           }
      }
    , objSupers = moduSupers
    }

moduleContext :: EdhWorld -> Object -> Context
moduleContext !world !modu = worldCtx
  { callStack          = objectScope worldCtx modu <| callStack worldCtx
  , contextExporting   = False
  , contextEffDefining = False
  }
  where !worldCtx = worldContext world


intplExpr :: EdhProgState -> Expr -> (Expr -> STM ()) -> STM ()
intplExpr !pgs !x !exit = case x of
  IntplExpr !x' -> runEdhProc pgs $ evalExpr x' $ \(OriginalValue !val _ _) ->
    contEdhSTM $ exit $ IntplSubs val
  PrefixExpr !pref !x' -> intplExpr pgs x' $ \x'' -> exit $ PrefixExpr pref x''
  IfExpr !cond !cons !alt -> intplExpr pgs cond $ \cond' ->
    intplExpr pgs cons $ \cons' -> case alt of
      Nothing -> exit $ IfExpr cond' cons' Nothing
      Just !altx ->
        intplExpr pgs altx $ \altx' -> exit $ IfExpr cond' cons' $ Just altx'
  CaseExpr !tgt !branches -> intplExpr pgs tgt $ \tgt' ->
    intplExpr pgs branches $ \branches' -> exit $ CaseExpr tgt' branches'
  DictExpr !entries -> seqcontSTM (intplDictEntry pgs <$> entries)
    $ \entries' -> exit $ DictExpr entries'
  ListExpr !es ->
    seqcontSTM (intplExpr pgs <$> es) $ \es' -> exit $ ListExpr es'
  ArgsPackExpr !argSenders -> seqcontSTM (intplArgSender pgs <$> argSenders)
    $ \argSenders' -> exit $ ArgsPackExpr argSenders'
  ParenExpr !x' -> intplExpr pgs x' $ \x'' -> exit $ ParenExpr x''
  BlockExpr !ss ->
    seqcontSTM (intplStmtSrc pgs <$> ss) $ \ss' -> exit $ BlockExpr ss'
  YieldExpr !x'             -> intplExpr pgs x' $ \x'' -> exit $ YieldExpr x''
  ForExpr !rcvs !fromX !doX -> intplExpr pgs fromX
    $ \fromX' -> intplExpr pgs doX $ \doX' -> exit $ ForExpr rcvs fromX' doX'
  AttrExpr !addr -> intplAttrAddr pgs addr $ \addr' -> exit $ AttrExpr addr'
  IndexExpr !v !t ->
    intplExpr pgs v $ \v' -> intplExpr pgs t $ \t' -> exit $ IndexExpr v' t'
  CallExpr !v !args -> intplExpr pgs v $ \v' ->
    seqcontSTM (intplArgSndr pgs <$> args) $ \args' -> exit $ CallExpr v' args'
  InfixExpr !op !lhe !rhe -> intplExpr pgs lhe
    $ \lhe' -> intplExpr pgs rhe $ \rhe' -> exit $ InfixExpr op lhe' rhe'
  ImportExpr !rcvrs !xFrom !maybeInto -> intplArgsRcvr pgs rcvrs $ \rcvrs' ->
    intplExpr pgs xFrom $ \xFrom' -> case maybeInto of
      Nothing     -> exit $ ImportExpr rcvrs' xFrom' Nothing
      Just !oInto -> intplExpr pgs oInto
        $ \oInto' -> exit $ ImportExpr rcvrs' xFrom' $ Just oInto'
  _ -> exit x

intplDictEntry
  :: EdhProgState
  -> (DictKeyExpr, Expr)
  -> ((DictKeyExpr, Expr) -> STM ())
  -> STM ()
intplDictEntry !pgs (k@LitDictKey{}, !x) !exit =
  intplExpr pgs x $ \x' -> exit (k, x')
intplDictEntry !pgs (AddrDictKey !k, !x) !exit = intplAttrAddr pgs k
  $ \k' -> intplExpr pgs x $ \x' -> exit (AddrDictKey k', x')
intplDictEntry !pgs (ExprDictKey !k, !x) !exit =
  intplExpr pgs k $ \k' -> intplExpr pgs x $ \x' -> exit (ExprDictKey k', x')

intplArgSender :: EdhProgState -> ArgSender -> (ArgSender -> STM ()) -> STM ()
intplArgSender !pgs (UnpackPosArgs !x) !exit =
  intplExpr pgs x $ \x' -> exit $ UnpackPosArgs x'
intplArgSender !pgs (UnpackKwArgs !x) !exit =
  intplExpr pgs x $ \x' -> exit $ UnpackKwArgs x'
intplArgSender !pgs (UnpackPkArgs !x) !exit =
  intplExpr pgs x $ \x' -> exit $ UnpackPkArgs x'
intplArgSender !pgs (SendPosArg !x) !exit =
  intplExpr pgs x $ \x' -> exit $ SendPosArg x'
intplArgSender !pgs (SendKwArg !addr !x) !exit =
  intplExpr pgs x $ \x' -> exit $ SendKwArg addr x'

intplAttrAddr :: EdhProgState -> AttrAddr -> (AttrAddr -> STM ()) -> STM ()
intplAttrAddr !pgs !addr !exit = case addr of
  IndirectRef !x' !a -> intplExpr pgs x' $ \x'' -> exit $ IndirectRef x'' a
  _                  -> exit addr

intplArgsRcvr
  :: EdhProgState -> ArgsReceiver -> (ArgsReceiver -> STM ()) -> STM ()
intplArgsRcvr !pgs !a !exit = case a of
  PackReceiver !rcvrs ->
    seqcontSTM (intplArgRcvr <$> rcvrs) $ \rcvrs' -> exit $ PackReceiver rcvrs'
  SingleReceiver !rcvr ->
    intplArgRcvr rcvr $ \rcvr' -> exit $ SingleReceiver rcvr'
  WildReceiver -> exit WildReceiver
 where
  intplArgRcvr :: ArgReceiver -> (ArgReceiver -> STM ()) -> STM ()
  intplArgRcvr !a' !exit' = case a' of
    RecvArg !attrAddr !maybeAddr !maybeDefault -> case maybeAddr of
      Nothing -> case maybeDefault of
        Nothing -> exit' $ RecvArg attrAddr Nothing Nothing
        Just !x ->
          intplExpr pgs x $ \x' -> exit' $ RecvArg attrAddr Nothing $ Just x'
      Just !addr -> intplAttrAddr pgs addr $ \addr' -> case maybeDefault of
        Nothing -> exit' $ RecvArg attrAddr (Just addr') Nothing
        Just !x -> intplExpr pgs x
          $ \x' -> exit' $ RecvArg attrAddr (Just addr') $ Just x'

    _ -> exit' a'

intplArgSndr :: EdhProgState -> ArgSender -> (ArgSender -> STM ()) -> STM ()
intplArgSndr !pgs !a !exit' = case a of
  UnpackPosArgs !v -> intplExpr pgs v $ \v' -> exit' $ UnpackPosArgs v'
  UnpackKwArgs  !v -> intplExpr pgs v $ \v' -> exit' $ UnpackKwArgs v'
  UnpackPkArgs  !v -> intplExpr pgs v $ \v' -> exit' $ UnpackPkArgs v'
  SendPosArg    !v -> intplExpr pgs v $ \v' -> exit' $ SendPosArg v'
  SendKwArg !n !v  -> intplExpr pgs v $ \v' -> exit' $ SendKwArg n v'

intplStmtSrc :: EdhProgState -> StmtSrc -> (StmtSrc -> STM ()) -> STM ()
intplStmtSrc !pgs (StmtSrc (!sp, !stmt)) !exit' =
  intplStmt pgs stmt $ \stmt' -> exit' $ StmtSrc (sp, stmt')

intplStmt :: EdhProgState -> Stmt -> (Stmt -> STM ()) -> STM ()
intplStmt !pgs !stmt !exit = case stmt of
  AtoIsoStmt !x         -> intplExpr pgs x $ \x' -> exit $ AtoIsoStmt x'
  GoStmt     !x         -> intplExpr pgs x $ \x' -> exit $ GoStmt x'
  DeferStmt  !x         -> intplExpr pgs x $ \x' -> exit $ DeferStmt x'
  LetStmt !rcvrs !sndrs -> intplArgsRcvr pgs rcvrs $ \rcvrs' ->
    seqcontSTM (intplArgSndr pgs <$> sndrs)
      $ \sndrs' -> exit $ LetStmt rcvrs' sndrs'
  ExtendsStmt !x           -> intplExpr pgs x $ \x' -> exit $ ExtendsStmt x'
  PerceiveStmt !sink !body -> intplExpr pgs sink
    $ \sink' -> intplExpr pgs body $ \body' -> exit $ PerceiveStmt sink' body'
  WhileStmt !cond !act -> intplExpr pgs cond
    $ \cond' -> intplStmtSrc pgs act $ \act' -> exit $ WhileStmt cond' act'
  ThrowStmt  !x -> intplExpr pgs x $ \x' -> exit $ ThrowStmt x'
  ReturnStmt !x -> intplExpr pgs x $ \x' -> exit $ ReturnStmt x'
  ExprStmt   !x -> intplExpr pgs x $ \x' -> exit $ ExprStmt x'
  _             -> exit stmt


evalLiteral :: Literal -> STM EdhValue
evalLiteral = \case
  DecLiteral    !v -> return (EdhDecimal v)
  StringLiteral !v -> return (EdhString v)
  BoolLiteral   !v -> return (EdhBool v)
  NilLiteral       -> return nil
  TypeLiteral !v   -> return (EdhType v)
  SinkCtor         -> EdhSink <$> newEventSink

evalAttrAddr :: AttrAddr -> EdhProcExit -> EdhProc
evalAttrAddr !addr !exit = do
  !pgs <- ask
  let !ctx   = edh'context pgs
      !scope = contextScope ctx
  case addr of
    ThisRef          -> exitEdhProc exit (EdhObject $ thisObject scope)
    ThatRef          -> exitEdhProc exit (EdhObject $ thatObject scope)
    SuperRef -> throwEdh UsageError "Can not address a single super alone"
    DirectRef !addr' -> contEdhSTM $ resolveEdhAttrAddr pgs addr' $ \key ->
      lookupEdhCtxAttr pgs scope key >>= \case
        EdhNil ->
          throwEdhSTM pgs EvalError $ "Not in scope: " <> T.pack (show addr')
        !val -> exitEdhSTM pgs exit val
    IndirectRef !tgtExpr !addr' ->
      contEdhSTM $ resolveEdhAttrAddr pgs addr' $ \key ->
        runEdhProc pgs $ getEdhAttr
          tgtExpr
          key
          (\tgtVal ->
            throwEdh EvalError
              $  "No such attribute "
              <> T.pack (show key)
              <> " from a "
              <> T.pack (edhTypeNameOf tgtVal)
              <> ": "
              <> T.pack (show tgtVal)
          )
          exit

evalDictLit
  :: [(DictKeyExpr, Expr)] -> [(EdhValue, EdhValue)] -> EdhProcExit -> EdhProc
evalDictLit [] !dsl !exit = ask >>= \pgs -> contEdhSTM $ do
  u   <- unsafeIOToSTM newUnique
  -- entry order in DictExpr is reversed as from source, we reversed it again
  -- here, so dsl now is the same order as in source code
  dsv <- iopdFromList dsl
  exitEdhSTM pgs exit $ EdhDict $ Dict u dsv
evalDictLit ((k, v) : entries) !dsl !exit = case k of
  LitDictKey !lit -> evalExpr v $ \(OriginalValue vVal _ _) -> do
    pgs <- ask
    contEdhSTM $ evalLiteral lit >>= \kVal ->
      runEdhProc pgs $ evalDictLit entries ((kVal, vVal) : dsl) exit
  AddrDictKey !addr -> evalAttrAddr addr $ \(OriginalValue !kVal _ _) ->
    evalExpr v $ \(OriginalValue !vVal _ _) ->
      evalDictLit entries ((kVal, vVal) : dsl) exit
  ExprDictKey !kExpr -> evalExpr kExpr $ \(OriginalValue !kVal _ _) ->
    evalExpr v $ \(OriginalValue !vVal _ _) ->
      evalDictLit entries ((kVal, vVal) : dsl) exit


evalExpr :: Expr -> EdhProcExit -> EdhProc
evalExpr !expr !exit = do
  !pgs <- ask
  let
    !ctx                   = edh'context pgs
    !world                 = contextWorld ctx
    !genr'caller           = generatorCaller ctx
    (StmtSrc (!srcPos, _)) = contextStmt ctx
    !scope                 = contextScope ctx
    this                   = thisObject scope
    chkExport :: AttrKey -> EdhValue -> STM ()
    chkExport !key !val =
      when (contextExporting ctx)
        $ lookupEntityAttr pgs (objEntity this) (AttrByName edhExportsMagicName)
        >>= \case
              EdhDict (Dict _ !thisExpDS) ->
                iopdInsert (attrKeyValue key) val thisExpDS
              _ -> do
                d <- createEdhDict [(attrKeyValue key, val)]
                changeEntityAttr pgs
                                 (objEntity this)
                                 (AttrByName edhExportsMagicName)
                                 d
    defEffect :: AttrKey -> EdhValue -> STM ()
    defEffect !key !val =
      lookupEntityAttr pgs (scopeEntity scope) (AttrByName edhEffectsMagicName)
        >>= \case
              EdhDict (Dict _ !effDS) ->
                iopdInsert (attrKeyValue key) val effDS
              _ -> do
                d <- createEdhDict [(attrKeyValue key, val)]
                changeEntityAttr pgs
                                 (scopeEntity scope)
                                 (AttrByName edhEffectsMagicName)
                                 d
  case expr of

    IntplSubs !val -> exitEdhProc exit val
    IntplExpr _ -> throwEdh UsageError "Interpolating out side of expr range."
    ExprWithSrc !x !sss -> contEdhSTM $ intplExpr pgs x $ \x' -> do
      let intplSrc :: SourceSeg -> (Text -> STM ()) -> STM ()
          intplSrc !ss !exit' = case ss of
            SrcSeg !s -> exit' s
            IntplSeg !sx ->
              runEdhProc pgs $ evalExpr sx $ \(OriginalValue !val _ _) ->
                edhValueRepr (edhDeCaseClose val) $ \(OriginalValue !rv _ _) ->
                  case rv of
                    EdhString !rs -> contEdhSTM $ exit' rs
                    _ -> error "bug: edhValueRepr returned non-string"
      seqcontSTM (intplSrc <$> sss) $ \ssl -> do
        u <- unsafeIOToSTM newUnique
        exitEdhSTM pgs exit $ EdhExpr u x' $ T.concat ssl

    LitExpr !lit -> contEdhSTM $ evalLiteral lit >>= exitEdhSTM pgs exit

    PrefixExpr !prefix !expr' -> case prefix of
      PrefixPlus  -> evalExpr expr' exit
      PrefixMinus -> evalExpr expr' $ \(OriginalValue !val _ _) ->
        case edhDeCaseClose val of
          (EdhDecimal !v) -> exitEdhProc exit (EdhDecimal (-v))
          !v ->
            throwEdh EvalError
              $  "Can not negate a "
              <> T.pack (edhTypeNameOf v)
              <> ": "
              <> T.pack (show v)
              <> " ❌"
      Not -> evalExpr expr' $ \(OriginalValue !val _ _) ->
        case edhDeCaseClose val of
          (EdhBool v) -> exitEdhProc exit (EdhBool $ not v)
          !v ->
            throwEdh EvalError
              $  "Expect bool but got a "
              <> T.pack (edhTypeNameOf v)
              <> ": "
              <> T.pack (show v)
              <> " ❌"
      Guard -> contEdhSTM $ do
        (consoleLogger $ worldConsole world)
          30
          (Just $ sourcePosPretty srcPos)
          (ArgsPack [EdhString "Standalone guard treated as plain value."]
                    odEmpty
          )
        runEdhProc pgs $ evalExpr expr' exit

    IfExpr !cond !cseq !alt -> evalExpr cond $ \(OriginalValue !val _ _) ->
      case edhDeCaseClose val of
        (EdhBool True ) -> evalExpr cseq exit
        (EdhBool False) -> case alt of
          Just elseClause -> evalExpr elseClause exit
          _               -> exitEdhProc exit nil
        !v ->
          -- we are so strongly typed
          throwEdh EvalError
            $  "Expecting a boolean value but got a "
            <> T.pack (edhTypeNameOf v)
            <> ": "
            <> T.pack (show v)
            <> " ❌"

    DictExpr !entries -> -- make sure dict k:v pairs are evaluated in same tx
      local (\s -> s { edh'in'tx = True })
        $ evalDictLit entries []
          -- restore tx state
        $ \(OriginalValue !dv _ _) -> local (const pgs) $ exitEdhProc exit dv

    ListExpr !xs -> -- make sure list values are evaluated in same tx
      local (\s -> s { edh'in'tx = True })
        $ evalExprs xs
        $ \(OriginalValue !tv _ _) -> case tv of
            EdhArgsPack (ArgsPack !l _) -> contEdhSTM $ do
              ll <- newTVar l
              u  <- unsafeIOToSTM newUnique
              -- restore tx state
              exitEdhSTM pgs exit (EdhList $ List u ll)
            _ -> error "bug"

    ArgsPackExpr !argSenders ->
      -- make sure packed values are evaluated in same tx
      local (\s -> s { edh'in'tx = True }) $ packEdhArgs argSenders $ \apk ->
        exitEdhProc exit $ EdhArgsPack apk

    ParenExpr !x     -> evalExpr x exit

    BlockExpr !stmts -> evalBlock stmts $ \(OriginalValue !blkResult _ _) ->
      -- a branch match won't escape out of a block, so adjacent blocks always
      -- execute sequentially
      exitEdhProc exit $ edhDeCaseClose blkResult

    CaseExpr !tgtExpr !branchesExpr ->
      evalExpr tgtExpr $ \(OriginalValue !tgtVal _ _) ->
        local
            (const pgs
              { edh'context = ctx { contextMatch = edhDeCaseClose tgtVal }
              }
            )
          $ evalCaseBlock branchesExpr
          -- restore program state after block done
          $ \(OriginalValue !blkResult _ _) ->
              local (const pgs) $ exitEdhProc exit blkResult


    -- yield stmt evals to the value of caller's `do` expression
    YieldExpr !yieldExpr ->
      evalExpr yieldExpr $ \(OriginalValue !valToYield _ _) ->
        case genr'caller of
          Nothing -> throwEdh EvalError "Unexpected yield"
          Just (pgsGenrCaller, yieldVal) ->
            contEdhSTM
              $ runEdhProc pgsGenrCaller
              $ yieldVal (edhDeCaseClose valToYield)
              $ \case
                  Left (pgsThrower, exv) ->
                    edhThrowSTM pgsThrower { edh'context = edh'context pgs } exv
                  Right !doResult -> case edhDeCaseClose doResult of
                    EdhContinue -> -- for loop should send nil here instead in
                      -- case continue issued from the do block
                      throwEdhSTM pgs EvalError "<continue> reached yield"
                    EdhBreak -> -- for loop is breaking, let the generator
                      -- return nil
                      -- the generator can intervene the return, that'll be
                      -- black magic
                      exitEdhSTM pgs exit $ EdhReturn EdhNil
                    EdhReturn EdhReturn{} -> -- this must be synthesiszed,
                      -- in case do block issued return, the for loop wrap it as
                      -- double return, so as to let the yield expr in the generator
                      -- propagate the value return, as the result of the for loop
                      -- the generator can intervene the return, that'll be
                      -- black magic
                      exitEdhSTM pgs exit doResult
                    EdhReturn{} -> -- for loop should have double-wrapped the
                      -- return, which is handled above, in case its do block
                      -- issued a return
                      throwEdhSTM pgs EvalError "<return> reached yield"
                    !val -> exitEdhSTM pgs exit val

    ForExpr !argsRcvr !iterExpr !doExpr ->
      contEdhSTM
        $ edhForLoop pgs argsRcvr iterExpr doExpr (const $ return ())
        $ \runLoop -> runEdhProc pgs (runLoop exit)

    PerformExpr !effAddr ->
      contEdhSTM $ resolveEdhAttrAddr pgs effAddr $ \ !effKey ->
        resolveEdhPerform pgs effKey $ exitEdhSTM pgs exit

    BehaveExpr !effAddr ->
      contEdhSTM $ resolveEdhAttrAddr pgs effAddr $ \ !effKey ->
        resolveEdhBehave pgs effKey $ exitEdhSTM pgs exit

    AttrExpr !addr -> evalAttrAddr addr exit

    IndexExpr !ixExpr !tgtExpr ->
      evalExpr ixExpr $ \(OriginalValue !ixV _ _) ->
        let !ixVal = edhDeCaseClose ixV
        in
          evalExpr tgtExpr $ \(OriginalValue !tgtV _ _) ->
            case edhDeCaseClose tgtV of

              -- indexing a dict
              (EdhDict (Dict _ !d)) ->
                contEdhSTM $ iopdLookup ixVal d >>= \case
                  Nothing  -> exitEdhSTM pgs exit nil
                  Just val -> exitEdhSTM pgs exit val

              -- indexing an apk
              EdhArgsPack (ArgsPack !args !kwargs) -> case edhUltimate ixVal of
                EdhDecimal !idxNum -> case D.decimalToInteger idxNum of
                  Just !i -> if i < 0 || i >= fromIntegral (length args)
                    then
                      throwEdh UsageError
                      $  "apk index out of bounds: "
                      <> T.pack (show i)
                      <> " vs "
                      <> T.pack (show $ length args)
                    else exitEdhProc exit $ args !! fromInteger i
                  Nothing ->
                    throwEdh UsageError
                      $  "Invalid numeric index to an apk: "
                      <> T.pack (show idxNum)
                EdhString !attrName -> exitEdhProc exit
                  $ odLookupDefault EdhNil (AttrByName attrName) kwargs
                EdhSymbol !attrSym -> exitEdhProc exit
                  $ odLookupDefault EdhNil (AttrBySym attrSym) kwargs
                !badIdxVal ->
                  throwEdh UsageError $ "Invalid index to an apk: " <> T.pack
                    (edhTypeNameOf badIdxVal)

              -- indexing an object, by calling its ([]) method with ixVal as the single arg
              EdhObject !obj ->
                contEdhSTM
                  $   lookupEdhObjAttr pgs obj (AttrByName "[]")
                  >>= \case

                        EdhNil ->
                          throwEdhSTM pgs EvalError
                            $  "No ([]) method from: "
                            <> T.pack (show obj)

                        EdhMethod !mth'proc -> runEdhProc pgs $ callEdhMethod
                          obj
                          mth'proc
                          (ArgsPack [ixVal] odEmpty)
                          id
                          exit

                        !badIndexer ->
                          throwEdhSTM pgs EvalError
                            $  "Malformed index method ([]) on "
                            <> T.pack (show obj)
                            <> " - "
                            <> T.pack (edhTypeNameOf badIndexer)
                            <> ": "
                            <> T.pack (show badIndexer)

              tgtVal ->
                throwEdh EvalError
                  $  "Don't know how to index "
                  <> T.pack (edhTypeNameOf tgtVal)
                  <> ": "
                  <> T.pack (show tgtVal)
                  <> " with "
                  <> T.pack (edhTypeNameOf ixVal)
                  <> ": "
                  <> T.pack (show ixVal)


    CallExpr !procExpr !argsSndr ->
      contEdhSTM
        $ resolveEdhCallee pgs procExpr
        $ \(OriginalValue !callee'val _ !callee'that, scopeMod) ->
            edhMakeCall pgs callee'val callee'that argsSndr scopeMod
              $ \mkCall -> runEdhProc pgs (mkCall exit)


    InfixExpr !opSym !lhExpr !rhExpr ->
      let
        notApplicable !lhVal !rhVal =
          throwEdhSTM pgs EvalError
            $  "Operator ("
            <> opSym
            <> ") not applicable to "
            <> T.pack (edhTypeNameOf $ edhUltimate lhVal)
            <> " and "
            <> T.pack (edhTypeNameOf $ edhUltimate rhVal)
        tryMagicMethod :: EdhValue -> EdhValue -> STM () -> STM ()
        tryMagicMethod !lhVal !rhVal !naExit = case edhUltimate lhVal of
          EdhObject !lhObj ->
            lookupEdhObjAttr pgs lhObj (AttrByName opSym) >>= \case
              EdhNil -> case edhUltimate rhVal of
                EdhObject !rhObj ->
                  lookupEdhObjAttr pgs rhObj (AttrByName $ opSym <> "@")
                    >>= \case
                          EdhNil              -> naExit
                          EdhMethod !mth'proc -> runEdhProc pgs $ callEdhMethod
                            rhObj
                            mth'proc
                            (ArgsPack [lhVal] odEmpty)
                            id
                            exit
                          !badEqMth ->
                            throwEdhSTM pgs UsageError
                              $  "Malformed magic method ("
                              <> opSym
                              <> "@) on "
                              <> T.pack (show rhObj)
                              <> " - "
                              <> T.pack (edhTypeNameOf badEqMth)
                              <> ": "
                              <> T.pack (show badEqMth)
                _ -> naExit
              EdhMethod !mth'proc -> runEdhProc pgs $ callEdhMethod
                lhObj
                mth'proc
                (ArgsPack [rhVal] odEmpty)
                id
                exit
              !badEqMth ->
                throwEdhSTM pgs UsageError
                  $  "Malformed magic method ("
                  <> opSym
                  <> ") on "
                  <> T.pack (show lhObj)
                  <> " - "
                  <> T.pack (edhTypeNameOf badEqMth)
                  <> ": "
                  <> T.pack (show badEqMth)
          _ -> case edhUltimate rhVal of
            EdhObject !rhObj ->
              lookupEdhObjAttr pgs rhObj (AttrByName $ opSym <> "@") >>= \case
                EdhNil              -> naExit
                EdhMethod !mth'proc -> runEdhProc pgs $ callEdhMethod
                  rhObj
                  mth'proc
                  (ArgsPack [lhVal] odEmpty)
                  id
                  exit
                !badEqMth ->
                  throwEdhSTM pgs UsageError
                    $  "Malformed magic method ("
                    <> opSym
                    <> "@) on "
                    <> T.pack (show rhObj)
                    <> " - "
                    <> T.pack (edhTypeNameOf badEqMth)
                    <> ": "
                    <> T.pack (show badEqMth)
            _ -> naExit
      in
        contEdhSTM $ resolveEdhCtxAttr pgs scope (AttrByName opSym) >>= \case
          Nothing ->
            runEdhProc pgs $ evalExpr lhExpr $ \(OriginalValue lhVal _ _) ->
              evalExpr rhExpr $ \(OriginalValue rhVal _ _) ->
                contEdhSTM $ tryMagicMethod lhVal rhVal $ notApplicable lhVal
                                                                        rhVal
          Just (!opVal, !op'lexi) -> case opVal of

            -- calling an intrinsic operator
            EdhIntrOp _ (IntrinOpDefi _ _ iop'proc) ->
              runEdhProc pgs
                $ iop'proc lhExpr rhExpr
                $ \rtn@(OriginalValue !rtnVal _ _) ->
                    case edhDeCaseClose rtnVal of
                      EdhDefault !defResult ->
                        evalExpr lhExpr $ \(OriginalValue lhVal _ _) ->
                          evalExpr rhExpr $ \(OriginalValue rhVal _ _) ->
                            contEdhSTM $ tryMagicMethod lhVal rhVal $ exitEdhSTM
                              pgs
                              exit
                              defResult
                      EdhContinue ->
                        evalExpr lhExpr $ \(OriginalValue lhVal _ _) ->
                          evalExpr rhExpr $ \(OriginalValue rhVal _ _) ->
                            contEdhSTM
                              $ tryMagicMethod lhVal rhVal
                              $ notApplicable lhVal rhVal
                      _ -> exitEdhProc' exit rtn

            -- calling an operator procedure
            EdhOprtor _ !op'pred !op'proc ->
              case procedure'args $ procedure'decl op'proc of
                -- 2 pos-args - simple lh/rh value receiving operator
                (PackReceiver [RecvArg{}, RecvArg{}]) ->
                  runEdhProc pgs
                    $ evalExpr lhExpr
                    $ \(OriginalValue lhVal _ _) ->
                        evalExpr rhExpr $ \(OriginalValue rhVal _ _) ->
                          callEdhOperator
                              (thatObject op'lexi)
                              op'proc
                              op'pred
                              [edhDeCaseClose lhVal, edhDeCaseClose rhVal]
                            $ \rtn@(OriginalValue !rtnVal _ _) ->
                                case edhDeCaseClose rtnVal of
                                  EdhDefault !defResult ->
                                    contEdhSTM
                                      $ tryMagicMethod lhVal rhVal
                                      $ exitEdhSTM pgs exit defResult
                                  EdhContinue ->
                                    contEdhSTM
                                      $ tryMagicMethod lhVal rhVal
                                      $ notApplicable lhVal rhVal
                                  _ -> exitEdhProc' exit rtn

                -- 3 pos-args - caller scope + lh/rh expr receiving operator
                (PackReceiver [RecvArg{}, RecvArg{}, RecvArg{}]) -> do
                  lhu          <- unsafeIOToSTM newUnique
                  rhu          <- unsafeIOToSTM newUnique
                  scopeWrapper <- mkScopeWrapper ctx scope
                  runEdhProc pgs
                    $ callEdhOperator
                        (thatObject op'lexi)
                        op'proc
                        op'pred
                        [ EdhObject scopeWrapper
                        , EdhExpr lhu lhExpr ""
                        , EdhExpr rhu rhExpr ""
                        ]
                    $ \rtn@(OriginalValue !rtnVal _ _) ->
                        case edhDeCaseClose rtnVal of
                          EdhDefault !defResult ->
                            evalExpr lhExpr $ \(OriginalValue lhVal _ _) ->
                              evalExpr rhExpr $ \(OriginalValue rhVal _ _) ->
                                contEdhSTM
                                  $ tryMagicMethod lhVal rhVal
                                  $ exitEdhSTM pgs exit defResult
                          EdhContinue ->
                            evalExpr lhExpr $ \(OriginalValue lhVal _ _) ->
                              evalExpr rhExpr $ \(OriginalValue rhVal _ _) ->
                                contEdhSTM
                                  $ tryMagicMethod lhVal rhVal
                                  $ notApplicable lhVal rhVal
                          _ -> exitEdhProc' exit rtn

                _ ->
                  throwEdhSTM pgs EvalError
                    $  "Invalid operator signature: "
                    <> T.pack (show $ procedure'args $ procedure'decl op'proc)

            _ ->
              throwEdhSTM pgs EvalError
                $  "Not callable "
                <> T.pack (edhTypeNameOf opVal)
                <> ": "
                <> T.pack (show opVal)
                <> " expressed with: "
                <> T.pack (show expr)

    NamespaceExpr pd@(ProcDecl !addr _ _) !argsSndr ->
      packEdhArgs argsSndr $ \apk ->
        contEdhSTM $ resolveEdhAttrAddr pgs addr $ \name -> do
          u <- unsafeIOToSTM newUnique
          let !cls = ProcDefi { procedure'uniq = u
                              , procedure'name = name
                              , procedure'lexi = Just scope
                              , procedure'decl = pd
                              }
          runEdhProc pgs
            $ createEdhObject cls apk
            $ \(OriginalValue !nsv _ _) -> case nsv of
                EdhObject !nso -> contEdhSTM $ do
                  lookupEdhObjAttr pgs nso (AttrByName "__repr__") >>= \case
                    EdhNil ->
                      changeEntityAttr pgs
                                       (objEntity nso)
                                       (AttrByName "__repr__")
                        $  EdhString
                        $  "namespace:"
                        <> if addr == NamedAttr "_"
                             then "<anonymous>"
                             else T.pack $ show addr
                    _ -> pure ()
                  when (addr /= NamedAttr "_") $ do
                    if contextEffDefining ctx
                      then defEffect name nsv
                      else unless (contextPure ctx)
                        $ changeEntityAttr pgs (scopeEntity scope) name nsv
                    chkExport name nsv
                  exitEdhSTM pgs exit nsv
                _ -> error "bug: createEdhObject returned non-object"

    ClassExpr pd@(ProcDecl !addr _ _) ->
      contEdhSTM $ resolveEdhAttrAddr pgs addr $ \name -> do
        u <- unsafeIOToSTM newUnique
        let !cls = EdhClass ProcDefi { procedure'uniq = u
                                     , procedure'name = name
                                     , procedure'lexi = Just scope
                                     , procedure'decl = pd
                                     }
        when (addr /= NamedAttr "_") $ do
          if contextEffDefining ctx
            then defEffect name cls
            else unless (contextPure ctx)
              $ changeEntityAttr pgs (scopeEntity scope) name cls
          chkExport name cls
        exitEdhSTM pgs exit cls

    MethodExpr pd@(ProcDecl !addr _ _) ->
      contEdhSTM $ resolveEdhAttrAddr pgs addr $ \name -> do
        u <- unsafeIOToSTM newUnique
        let mth = EdhMethod ProcDefi { procedure'uniq = u
                                     , procedure'name = name
                                     , procedure'lexi = Just scope
                                     , procedure'decl = pd
                                     }
        when (addr /= NamedAttr "_") $ do
          if contextEffDefining ctx
            then defEffect name mth
            else unless (contextPure ctx)
              $ changeEntityAttr pgs (scopeEntity scope) name mth
          chkExport name mth
        exitEdhSTM pgs exit mth

    GeneratorExpr pd@(ProcDecl !addr _ _) ->
      contEdhSTM $ resolveEdhAttrAddr pgs addr $ \name -> do
        u <- unsafeIOToSTM newUnique
        let gdf = EdhGnrtor ProcDefi { procedure'uniq = u
                                     , procedure'name = name
                                     , procedure'lexi = Just scope
                                     , procedure'decl = pd
                                     }
        when (addr /= NamedAttr "_") $ do
          if contextEffDefining ctx
            then defEffect name gdf
            else unless (contextPure ctx)
              $ changeEntityAttr pgs (scopeEntity scope) name gdf
          chkExport name gdf
        exitEdhSTM pgs exit gdf

    InterpreterExpr pd@(ProcDecl !addr _ _) ->
      contEdhSTM $ resolveEdhAttrAddr pgs addr $ \name -> do
        u <- unsafeIOToSTM newUnique
        let mth = EdhIntrpr ProcDefi { procedure'uniq = u
                                     , procedure'name = name
                                     , procedure'lexi = Just scope
                                     , procedure'decl = pd
                                     }
        when (addr /= NamedAttr "_") $ do
          if contextEffDefining ctx
            then defEffect name mth
            else unless (contextPure ctx)
              $ changeEntityAttr pgs (scopeEntity scope) name mth
          chkExport name mth
        exitEdhSTM pgs exit mth

    ProducerExpr pd@(ProcDecl !addr !args _) ->
      contEdhSTM $ resolveEdhAttrAddr pgs addr $ \name -> do
        u <- unsafeIOToSTM newUnique
        let mth = EdhPrducr ProcDefi { procedure'uniq = u
                                     , procedure'name = name
                                     , procedure'lexi = Just scope
                                     , procedure'decl = pd
                                     }
        unless (receivesNamedArg "outlet" args) $ throwEdhSTM
          pgs
          EvalError
          "a producer procedure should receive a `outlet` keyword argument"
        when (addr /= NamedAttr "_") $ do
          if contextEffDefining ctx
            then defEffect name mth
            else unless (contextPure ctx)
              $ changeEntityAttr pgs (scopeEntity scope) name mth
          chkExport name mth
        exitEdhSTM pgs exit mth

    OpDeclExpr !opSym !opPrec opProc@(ProcDecl _ _ !pb) ->
      if contextEffDefining ctx
        then throwEdh UsageError "Why should an operator be effectful?"
        else case pb of
          -- support re-declaring an existing operator to another name,
          -- with possibly a different precedence
          Left (StmtSrc (_, ExprStmt (AttrExpr (DirectRef (NamedAttr !origOpSym)))))
            -> contEdhSTM $ do
              let redeclareOp !origOp = do
                    unless (contextPure ctx) $ changeEntityAttr
                      pgs
                      (scopeEntity scope)
                      (AttrByName opSym)
                      origOp
                    when (contextExporting ctx)
                      $   lookupEntityAttr pgs
                                           (objEntity this)
                                           (AttrByName edhExportsMagicName)
                      >>= \case
                            EdhDict (Dict _ !thisExpDS) ->
                              iopdInsert (EdhString opSym) origOp thisExpDS
                            _ -> do
                              d <- createEdhDict [(EdhString opSym, origOp)]
                              changeEntityAttr
                                pgs
                                (objEntity this)
                                (AttrByName edhExportsMagicName)
                                d
                    exitEdhSTM pgs exit origOp
              lookupEdhCtxAttr pgs scope (AttrByName origOpSym) >>= \case
                EdhNil ->
                  throwEdhSTM pgs EvalError
                    $  "Original operator ("
                    <> origOpSym
                    <> ") not in scope"
                origOp@EdhIntrOp{} -> redeclareOp origOp
                origOp@EdhOprtor{} -> redeclareOp origOp
                val ->
                  throwEdhSTM pgs EvalError
                    $  "Can not re-declare a "
                    <> T.pack (edhTypeNameOf val)
                    <> ": "
                    <> T.pack (show val)
                    <> " as an operator"
          _ -> contEdhSTM $ do
            validateOperDecl pgs opProc
            u <- unsafeIOToSTM newUnique
            let op = EdhOprtor
                  opPrec
                  Nothing
                  ProcDefi { procedure'uniq = u
                           , procedure'name = AttrByName opSym
                           , procedure'lexi = Just scope
                           , procedure'decl = opProc
                           }
            unless (contextPure ctx)
              $ changeEntityAttr pgs (scopeEntity scope) (AttrByName opSym) op
            when (contextExporting ctx)
              $   lookupEntityAttr pgs
                                   (objEntity this)
                                   (AttrByName edhExportsMagicName)
              >>= \case
                    EdhDict (Dict _ !thisExpDS) ->
                      iopdInsert (EdhString opSym) op thisExpDS
                    _ -> do
                      d <- createEdhDict [(EdhString opSym, op)]
                      changeEntityAttr pgs
                                       (objEntity this)
                                       (AttrByName edhExportsMagicName)
                                       d
            exitEdhSTM pgs exit op

    OpOvrdExpr !opSym !opProc !opPrec -> if contextEffDefining ctx
      then throwEdh UsageError "Why should an operator be effectful?"
      else contEdhSTM $ do
        validateOperDecl pgs opProc
        let
          findPredecessor :: STM (Maybe EdhValue)
          findPredecessor =
            lookupEdhCtxAttr pgs scope (AttrByName opSym) >>= \case
              EdhNil -> -- do
                -- (EdhConsole logger _) <- readTMVar $ worldConsole world
                -- logger 30 (Just $ sourcePosPretty srcPos)
                --   $ ArgsPack
                --       [EdhString "overriding an unavailable operator"]
                --       odEmpty
                return Nothing
              op@EdhIntrOp{} -> return $ Just op
              op@EdhOprtor{} -> return $ Just op
              opVal          -> do
                (consoleLogger $ worldConsole world)
                    30
                    (Just $ sourcePosPretty srcPos)
                  $ ArgsPack
                      [ EdhString
                        $  "overriding an invalid operator "
                        <> T.pack (edhTypeNameOf opVal)
                        <> ": "
                        <> T.pack (show opVal)
                      ]
                      odEmpty
                return Nothing
        predecessor <- findPredecessor
        u           <- unsafeIOToSTM newUnique
        let op = EdhOprtor
              opPrec
              predecessor
              ProcDefi { procedure'uniq = u
                       , procedure'name = AttrByName opSym
                       , procedure'lexi = Just scope
                       , procedure'decl = opProc
                       }
        unless (contextPure ctx)
          $ changeEntityAttr pgs (scopeEntity scope) (AttrByName opSym) op
        when (contextExporting ctx)
          $   lookupEntityAttr pgs
                               (objEntity this)
                               (AttrByName edhExportsMagicName)
          >>= \case
                EdhDict (Dict _ !thisExpDS) ->
                  iopdInsert (EdhString opSym) op thisExpDS
                _ -> do
                  d <- createEdhDict [(EdhString opSym, op)]
                  changeEntityAttr pgs
                                   (objEntity this)
                                   (AttrByName edhExportsMagicName)
                                   d
        exitEdhSTM pgs exit op


    ExportExpr !exps ->
      local
          (const pgs
            { edh'context = (edh'context pgs) { contextExporting = True }
            }
          )
        $ evalExpr exps
        $ \rtn -> local (const pgs) $ exitEdhProc' exit rtn


    ImportExpr !argsRcvr !srcExpr !maybeInto -> case maybeInto of
      Nothing        -> importInto (scopeEntity scope) argsRcvr srcExpr exit
      Just !intoExpr -> evalExpr intoExpr $ \(OriginalValue !intoVal _ _) ->
        case intoVal of
          EdhObject !intoObj ->
            importInto (objEntity intoObj) argsRcvr srcExpr exit
          _ ->
            throwEdh UsageError
              $  "Can only import into an object, not a "
              <> T.pack (edhTypeNameOf intoVal)

    -- _ -> throwEdh EvalError $ "Eval not yet impl for: " <> T.pack (show expr)


validateOperDecl :: EdhProgState -> ProcDecl -> STM ()
validateOperDecl !pgs (ProcDecl _ !op'args _) = case op'args of
  -- 2 pos-args - simple lh/rh value receiving operator
  (PackReceiver [RecvArg _lhName Nothing Nothing, RecvArg _rhName Nothing Nothing])
    -> return ()
  -- 3 pos-args - caller scope + lh/rh expr receiving operator
  (PackReceiver [RecvArg _scopeName Nothing Nothing, RecvArg _lhName Nothing Nothing, RecvArg _rhName Nothing Nothing])
    -> return ()
  _ -> throwEdhSTM pgs EvalError "Invalid operator signature"


getEdhAttr :: Expr -> AttrKey -> (EdhValue -> EdhProc) -> EdhProcExit -> EdhProc
getEdhAttr !fromExpr !key !exitNoAttr !exit = do
  !pgs <- ask
  let ctx          = edh'context pgs
      scope        = contextScope ctx
      this         = thisObject scope
      that         = thatObject scope
      thisObjScope = objectScope ctx this
      chkExit :: Object -> OriginalValue -> STM ()
      chkExit !obj rtn@(OriginalValue !rtnVal _ _) = case rtnVal of
        EdhDescriptor !getter _ -> runEdhProc pgs
          $ callEdhMethod obj getter (ArgsPack [] odEmpty) id exit
        _ -> exitEdhSTM' pgs exit rtn
      trySelfMagic :: Object -> EdhProc -> EdhProc
      trySelfMagic !obj !noMagic =
        contEdhSTM $ lookupEntityAttr pgs (objEntity obj) key >>= \case
          EdhNil ->
            lookupEntityAttr pgs (objEntity obj) (AttrByName "@") >>= \case
              EdhNil         -> runEdhProc pgs $ noMagic
              EdhMethod !mth -> runEdhProc pgs $ callEdhMethod
                obj
                mth
                (ArgsPack [attrKeyValue key] odEmpty)
                id
                exit
              !badMth ->
                throwEdhSTM pgs UsageError
                  $  "Malformed magic (@) method of "
                  <> T.pack (edhTypeNameOf badMth)
          !attrVal -> -- don't shadow an attr directly available from an obj
            chkExit obj $ OriginalValue attrVal (objectScope ctx obj) obj
  case fromExpr of
    -- give super objects the magical power to intercept
    -- attribute access on descendant objects, via `this` ref
    AttrExpr ThisRef ->
      let noMagic :: EdhProc
          noMagic = contEdhSTM $ lookupEdhObjAttr pgs this key >>= \case
            EdhNil -> runEdhProc pgs $ exitNoAttr $ EdhObject this
            !val   -> chkExit this $ OriginalValue val thisObjScope this
      in  getEdhAttrWSM (AttrByName "@<-")
                        this
                        key
                        (trySelfMagic this noMagic)
                        exit
    -- no super magic layer laid over access via `that` ref
    AttrExpr ThatRef -> contEdhSTM $ lookupEdhObjAttr pgs that key >>= \case
      EdhNil ->
        runEdhProc pgs $ trySelfMagic that $ exitNoAttr $ EdhObject that
      !val -> chkExit that $ OriginalValue val thisObjScope that
    -- give super objects of an super object the metamagical power to
    -- intercept attribute access on super object, via `super` ref
    AttrExpr SuperRef ->
      let
        noMagic :: EdhProc
        noMagic = contEdhSTM $ lookupEdhSuperAttr pgs this key >>= \case
          EdhNil -> runEdhProc pgs $ exitNoAttr $ EdhObject this
          !val   -> chkExit this $ OriginalValue val thisObjScope this
        getFromSupers :: [Object] -> EdhProc
        getFromSupers []                   = noMagic
        getFromSupers (super : restSupers) = getEdhAttrWSM
          (AttrByName "@<-^")
          super
          key
          (getFromSupers restSupers)
          exit
      in
        contEdhSTM
        $   readTVar (objSupers this)
        >>= runEdhProc pgs
        .   getFromSupers
    _ -> evalExpr fromExpr $ \(OriginalValue !fromVal _ _) ->
      case edhUltimate fromVal of
        EdhObject !obj -> do
          -- give super objects the magical power to intercept
          -- attribute access on descendant objects, via obj ref
          let fromScope = objectScope ctx obj
              noMagic :: EdhProc
              noMagic = contEdhSTM $ lookupEdhObjAttr pgs obj key >>= \case
                EdhNil -> runEdhProc pgs $ exitNoAttr fromVal
                !val   -> chkExit obj $ OriginalValue val fromScope obj
          getEdhAttrWSM (AttrByName "@<-*")
                        obj
                        key
                        (trySelfMagic obj noMagic)
                        exit

        -- getting attr from an apk
        EdhArgsPack (ArgsPack _ !kwargs) ->
          exitEdhProc exit $ odLookupDefault EdhNil key kwargs

        -- virtual attrs by magic method from context
        !val -> case key of
          AttrByName !attrName -> contEdhSTM $ do
            let !magicName =
                  "__" <> T.pack (edhTypeNameOf val) <> "_" <> attrName <> "__"
            lookupEdhCtxAttr pgs scope (AttrByName magicName) >>= \case
              EdhMethod !mth -> runEdhProc pgs
                $ callEdhMethod this mth (ArgsPack [val] odEmpty) id exit
              _ -> runEdhProc pgs $ exitNoAttr fromVal
          _ -> exitNoAttr fromVal


-- There're 2 tiers of magic happen during object attribute resolution in Edh.
--  *) a magical super controls its direct descendants in behaving as an object, by
--     intercepting the attr resolution
--  *) a metamagical super controls its direct descendants in behaving as a magical
--     super, by intercepting the magic method (as attr) resolution

edhMetaMagicSpell :: AttrKey
edhMetaMagicSpell = AttrByName "!<-"

-- | Try get an attribute from an object, with super magic
getEdhAttrWSM
  :: AttrKey -> Object -> AttrKey -> EdhProc -> EdhProcExit -> EdhProc
getEdhAttrWSM !magicSpell !obj !key !exitNoMagic !exit = do
  !pgs <- ask
  let
    ctx = edh'context pgs
    getViaSupers :: [Object] -> EdhProc
    getViaSupers [] = exitNoMagic
    getViaSupers (super : restSupers) =
      getEdhAttrWSM edhMetaMagicSpell super magicSpell noMetamagic
        $ \(OriginalValue !magicVal !magicScope _) ->
            case edhUltimate magicVal of
              EdhMethod magicMth ->
                contEdhSTM $ withMagicMethod magicScope magicMth
              _ -> throwEdh EvalError $ "Invalid magic method type: " <> T.pack
                (edhTypeNameOf magicVal)
     where
      superScope = objectScope ctx super
      noMetamagic :: EdhProc
      noMetamagic =
        contEdhSTM
          $   edhUltimate
          <$> lookupEdhObjAttr pgs super magicSpell
          >>= \case
                EdhNil              -> runEdhProc pgs $ getViaSupers restSupers
                EdhMethod !magicMth -> withMagicMethod superScope magicMth
                magicVal ->
                  throwEdhSTM pgs EvalError
                    $  "Invalid magic method type: "
                    <> T.pack (edhTypeNameOf magicVal)
      withMagicMethod :: Scope -> ProcDefi -> STM ()
      withMagicMethod !magicScope !magicMth =
        runEdhProc pgs
          $ callEdhMethod obj magicMth (ArgsPack [attrKeyValue key] odEmpty) id
          $ \(OriginalValue !magicRtn _ _) -> case magicRtn of
              EdhContinue -> getViaSupers restSupers
              _ -> exitEdhProc' exit $ OriginalValue magicRtn magicScope obj
  contEdhSTM $ readTVar (objSupers obj) >>= runEdhProc pgs . getViaSupers

-- | Try set an attribute into an object, with super magic
setEdhAttrWSM
  :: EdhProgState
  -> AttrKey
  -> Object
  -> AttrKey
  -> EdhValue
  -> EdhProc
  -> EdhProcExit
  -> EdhProc
setEdhAttrWSM !pgsAfter !magicSpell !obj !key !val !exitNoMagic !exit = do
  !pgs <- ask
  contEdhSTM $ readTVar (objSupers obj) >>= runEdhProc pgs . setViaSupers
 where
  setViaSupers :: [Object] -> EdhProc
  setViaSupers []                   = exitNoMagic
  setViaSupers (super : restSupers) = do
    !pgs <- ask
    let
      noMetamagic :: EdhProc
      noMetamagic =
        contEdhSTM
          $   edhUltimate
          <$> lookupEdhObjAttr pgs super magicSpell
          >>= \case
                EdhNil              -> runEdhProc pgs $ setViaSupers restSupers
                EdhMethod !magicMth -> withMagicMethod magicMth
                magicVal ->
                  throwEdhSTM pgs EvalError
                    $  "Invalid magic method type: "
                    <> T.pack (edhTypeNameOf magicVal)
      withMagicMethod :: ProcDefi -> STM ()
      withMagicMethod !magicMth =
        runEdhProc pgs
          $ callEdhMethod obj
                          magicMth
                          (ArgsPack [attrKeyValue key, val] odEmpty)
                          id
          $ \(OriginalValue !magicRtn _ _) -> case magicRtn of
              EdhContinue -> setViaSupers restSupers
              _           -> local (const pgsAfter) $ exitEdhProc exit magicRtn
    getEdhAttrWSM edhMetaMagicSpell super magicSpell noMetamagic
      $ \(OriginalValue !magicVal _ _) -> case edhUltimate magicVal of
          EdhMethod !magicMth -> contEdhSTM $ withMagicMethod magicMth
          _ -> throwEdh EvalError $ "Invalid magic method type: " <> T.pack
            (edhTypeNameOf magicVal)


setEdhAttr
  :: EdhProgState -> Expr -> AttrKey -> EdhValue -> EdhProcExit -> EdhProc
setEdhAttr !pgsAfter !tgtExpr !key !val !exit = do
  !pgs <- ask
  let !scope = contextScope $ edh'context pgs
      !this  = thisObject scope
      !that  = thatObject scope
  case tgtExpr of
    -- give super objects the magical power to intercept
    -- attribute assignment to descendant objects, via `this` ref
    AttrExpr ThisRef ->
      let noMagic :: EdhProc
          noMagic =
              contEdhSTM $ changeEdhObjAttr pgs this key val $ \ !valSet ->
                runEdhProc pgsAfter $ exitEdhProc exit valSet
      in  setEdhAttrWSM pgsAfter (AttrByName "<-@") this key val noMagic exit
    -- no magic layer laid over assignment via `that` ref
    AttrExpr ThatRef ->
      contEdhSTM $ changeEdhObjAttr pgs that key val $ \ !valSet ->
        runEdhProc pgsAfter $ exitEdhProc exit valSet
    -- not allowing assignment via super
    AttrExpr SuperRef -> throwEdh EvalError "Can not assign via super"
    -- give super objects the magical power to intercept
    -- attribute assignment to descendant objects, via obj ref
    _                 -> evalExpr tgtExpr $ \(OriginalValue !tgtVal _ _) ->
      case edhUltimate tgtVal of
        EdhObject !tgtObj ->
          let noMagic :: EdhProc
              noMagic =
                  contEdhSTM $ changeEdhObjAttr pgs tgtObj key val $ \ !valSet ->
                    runEdhProc pgsAfter $ exitEdhProc exit valSet
          in  setEdhAttrWSM pgsAfter
                            (AttrByName "*<-@")
                            tgtObj
                            key
                            val
                            noMagic
                            exit
        _ ->
          throwEdh EvalError
            $  "Invalid assignment target, it's a "
            <> T.pack (edhTypeNameOf tgtVal)
            <> ": "
            <> T.pack (show tgtVal)


edhMakeCall
  :: EdhProgState
  -> EdhValue
  -> Object
  -> ArgsPacker
  -> (Scope -> Scope)
  -> ((EdhProcExit -> EdhProc) -> STM ())
  -> STM ()
edhMakeCall !pgsCaller !callee'val !callee'that !argsSndr !scopeMod !callMaker
  = case callee'val of
    EdhIntrpr{} -> runEdhProc pgsCaller $ packEdhExprs argsSndr $ \apk ->
      contEdhSTM
        $ edhMakeCall' pgsCaller callee'val callee'that apk scopeMod callMaker
    _ -> runEdhProc pgsCaller $ packEdhArgs argsSndr $ \apk ->
      contEdhSTM
        $ edhMakeCall' pgsCaller callee'val callee'that apk scopeMod callMaker

edhMakeCall'
  :: EdhProgState
  -> EdhValue
  -> Object
  -> ArgsPack
  -> (Scope -> Scope)
  -> ((EdhProcExit -> EdhProc) -> STM ())
  -> STM ()
edhMakeCall' !pgsCaller !callee'val !callee'that apk@(ArgsPack !args !kwargs) !scopeMod !callMaker
  = case callee'val of

    -- calling a class (constructor) procedure
    EdhClass  !cls      -> callMaker $ \exit -> constructEdhObject cls apk exit

    -- calling a method procedure
    EdhMethod !mth'proc -> callMaker
      $ \exit -> callEdhMethod callee'that mth'proc apk scopeMod exit

    -- calling an interpreter procedure
    EdhIntrpr !mth'proc -> do
      -- an Edh interpreter proc needs a `callerScope` as its 1st arg,
      -- while a host interpreter proc doesn't.
      apk' <- case procedure'body $ procedure'decl mth'proc of
        Right _ -> return apk
        Left  _ -> do
          let callerCtx = edh'context pgsCaller
          !argCallerScope <- mkScopeWrapper callerCtx $ contextScope callerCtx
          return $ ArgsPack (EdhObject argCallerScope : args) kwargs
      callMaker $ \exit -> callEdhMethod callee'that mth'proc apk' scopeMod exit

    -- calling a producer procedure
    EdhPrducr !mth'proc -> case procedure'body $ procedure'decl mth'proc of
      Right _ -> throwEdhSTM pgsCaller EvalError "bug: host producer procedure"
      Left !pb -> case edhUltimate <$> odLookup (AttrByName "outlet") kwargs of
        Nothing -> do
          outlet <- newEventSink
          callMaker $ \exit -> launchEventProducer exit outlet $ callEdhMethod'
            Nothing
            callee'that
            mth'proc
            pb
            (  ArgsPack args
            $  odFromList
            $  odToList kwargs
            ++ [(AttrByName "outlet", EdhSink outlet)]
            )
            scopeMod
            edhEndOfProc
        Just (EdhSink !outlet) -> callMaker $ \exit ->
          launchEventProducer exit outlet $ callEdhMethod'
            Nothing
            callee'that
            mth'proc
            pb
            (ArgsPack args kwargs)
            scopeMod
            edhEndOfProc
        Just !badVal ->
          throwEdhSTM pgsCaller UsageError
            $  "The value passed to a producer as `outlet` found to be a "
            <> T.pack (edhTypeNameOf badVal)

    -- calling a generator
    (EdhGnrtor _) -> throwEdhSTM
      pgsCaller
      EvalError
      "Can only call a generator method by for-from-do"

    -- calling an object
    (EdhObject !o) ->
      lookupEdhObjAttr pgsCaller o (AttrByName "__call__") >>= \case
        EdhMethod !callMth -> callMaker
          $ \exit -> callEdhMethod callee'that callMth apk scopeMod exit
        _ -> throwEdhSTM pgsCaller EvalError "No __call__ method on object"

    _ ->
      throwEdhSTM pgsCaller EvalError
        $  "Can not call a "
        <> T.pack (edhTypeNameOf callee'val)
        <> ": "
        <> T.pack (show callee'val)


-- todo this should really be in `CoreLang.hs`, but there has no access to 
--      'throwEdhSTM' without cyclic imports, maybe some day we shall try
--      `.hs-boot` files
-- | resolve an attribute addressor, either alphanumeric named or symbolic
resolveEdhAttrAddr
  :: EdhProgState -> AttrAddressor -> (AttrKey -> STM ()) -> STM ()
resolveEdhAttrAddr _ (NamedAttr !attrName) !exit = exit (AttrByName attrName)
resolveEdhAttrAddr !pgs (SymbolicAttr !symName) !exit =
  let scope = contextScope $ edh'context pgs
  in  resolveEdhCtxAttr pgs scope (AttrByName symName) >>= \case
        Just (!val, _) -> case val of
          (EdhSymbol !symVal ) -> exit (AttrBySym symVal)
          (EdhString !nameVal) -> exit (AttrByName nameVal)
          _ ->
            throwEdhSTM pgs EvalError
              $  "Not a symbol/string as "
              <> symName
              <> ", it is a "
              <> T.pack (edhTypeNameOf val)
              <> ": "
              <> T.pack (show val)
        Nothing ->
          throwEdhSTM pgs EvalError
            $  "No symbol/string named "
            <> T.pack (show symName)
            <> " available"
{-# INLINE resolveEdhAttrAddr #-}


-- | Wait an stm action without tracking the retries
edhPerformSTM :: EdhProgState -> STM a -> (a -> EdhProc) -> STM ()
edhPerformSTM !pgs !act !exit = if edh'in'tx pgs
  then throwEdhSTM pgs UsageError "You don't wait stm from within a transaction"
  else writeTBQueue (edh'task'queue pgs) $ EdhSTMTask pgs act exit

-- | Perform a synchronous IO action from an Edh thread
--
-- CAVEAT during the IO action:
--         * event perceivers won't fire
--         * the Edh thread won't terminate with the Edh program
--        so 'edhPerformSTM' is more preferable whenever possible
edhPerformIO :: EdhProgState -> IO a -> (a -> EdhProc) -> STM ()
edhPerformIO !pgs !act !exit = if edh'in'tx pgs
  then throwEdhSTM pgs UsageError "You don't perform IO within a transaction"
  else writeTBQueue (edh'task'queue pgs) $ EdhIOTask pgs act exit


-- | Create an Edh error as both an Edh exception value and a host exception
createEdhError
  :: EdhProgState
  -> EdhErrorTag
  -> Text
  -> (EdhValue -> SomeException -> STM ())
  -> STM ()
createEdhError !pgs !et !msg !exit = getEdhErrClass pgs et >>= \ec ->
  runEdhProc pgs
    $ constructEdhObject ec (ArgsPack [EdhString msg] odEmpty)
    $ \(OriginalValue !exv _ _) -> case exv of
        EdhObject !exo -> contEdhSTM $ do
          esd <- readTVar $ entity'store $ objEntity exo
          exit exv $ toException esd
        _ -> error "bug: constructEdhObject returned non-object"

-- | Convert an arbitrary Edh error to exception
fromEdhError :: EdhProgState -> EdhValue -> (SomeException -> STM ()) -> STM ()
fromEdhError !pgs !exv !exit = case exv of
  EdhNil ->
    throwSTM
      $ EdhError UsageError "false Edh error to fromEdhError"
      $ getEdhCallContext 0 pgs
  EdhObject !exo -> do
    esd <- readTVar $ entity'store $ objEntity exo
    case fromDynamic esd of
      Just (e :: SomeException, _apk :: ArgsPack) -> exit e
      Nothing -> case fromDynamic esd of
        Just (e :: SomeException) -> exit e
        Nothing                   -> ioErr
  _ -> ioErr
 where
  ioErr = edhValueReprSTM pgs exv $ \exr ->
    exit $ toException $ EdhError EvalError exr $ getEdhCallContext 0 pgs

-- | Convert an arbitrary exception to an Edh error
toEdhError :: EdhProgState -> SomeException -> (EdhValue -> STM ()) -> STM ()
toEdhError !pgs !e !exit = toEdhError' pgs e (ArgsPack [] odEmpty) exit
-- | Convert an arbitrary exception plus details to an Edh error
toEdhError'
  :: EdhProgState -> SomeException -> ArgsPack -> (EdhValue -> STM ()) -> STM ()
toEdhError' !pgs !e !details !exit = case fromException e :: Maybe EdhError of
  Just !err -> case err of
    EdhError !et _ _ -> getEdhErrClass pgs et >>= withErrCls
    EdhPeerError{} ->
      _getEdhErrClass pgs (AttrByName "PeerError") >>= withErrCls
    EdhIOError{} -> _getEdhErrClass pgs (AttrByName "IOError") >>= withErrCls
    ProgramHalt{} ->
      _getEdhErrClass pgs (AttrByName "ProgramHalt") >>= withErrCls
  Nothing -> _getEdhErrClass pgs (AttrByName "IOError") >>= withErrCls
 where
  withErrCls :: Class -> STM ()
  withErrCls !ec = do
    !esm <- createErrEntManipulater $ procedureName ec
    !ent <- createSideEntity esm $ toDyn (e, details)
    !exo <- viewAsEdhObject ent ec []
    exit $ EdhObject exo

-- | Get Edh class for an error tag
getEdhErrClass :: EdhProgState -> EdhErrorTag -> STM Class
getEdhErrClass !pgs !et = _getEdhErrClass pgs eck
 where
  eck = AttrByName $ ecn et
  ecn :: EdhErrorTag -> Text
  ecn = \case -- cross check with 'createEdhWorld' for type safety
    EdhException -> "Exception"
    PackageError -> "PackageError"
    ParseError   -> "ParseError"
    EvalError    -> "EvalError"
    UsageError   -> "UsageError"
_getEdhErrClass :: EdhProgState -> AttrKey -> STM Class
_getEdhErrClass !pgs !eck =
  lookupEntityAttr pgs
                   (scopeEntity $ worldScope $ contextWorld $ edh'context pgs)
                   eck
    >>= \case
          EdhClass !ec -> return ec
          badVal ->
            throwSTM
              $ EdhError
                  UsageError
                  (  "Edh error class "
                  <> T.pack (show eck)
                  <> " in the world found to be a "
                  <> T.pack (edhTypeNameOf badVal)
                  )
              $ getEdhCallContext 0 pgs

createErrEntManipulater :: Text -> STM EntityManipulater
createErrEntManipulater !clsName = do
  let the'lookup'entity'attr _ !k !esd = case fromDynamic esd of
        Just (e :: SomeException, apk :: ArgsPack) -> case k of
          AttrByName "__repr__" -> return $ EdhString $ T.pack $ show e
          AttrByName "details"  -> return $ EdhArgsPack apk
          _                     -> return nil
        Nothing -> case fromDynamic esd of
          Just (apk :: ArgsPack) -> case k of
            AttrByName "__repr__" ->
              return $ EdhString $ clsName <> T.pack (show apk)
            AttrByName "details" -> return $ EdhArgsPack apk
            _                    -> return nil
          Nothing -> case fromDynamic esd of
            Just (e :: SomeException) -> case k of
              AttrByName "__repr__" -> return $ EdhString $ T.pack $ show e
              AttrByName "details" ->
                return $ EdhArgsPack $ ArgsPack [] odEmpty
              _ -> return nil
            Nothing -> case k of
              AttrByName "__repr__" -> return $ EdhString $ clsName <> "()"
              AttrByName "details" ->
                return $ EdhArgsPack $ ArgsPack [] odEmpty
              _ -> return nil
      the'all'entity'attrs _ _ = return []
      the'change'entity'attr !pgs _ _ _ =
        throwSTM
          $ EdhError UsageError "Edh error object not changable"
          $ getEdhCallContext 0 pgs
      the'update'entity'attrs !pgs _ _ =
        throwSTM
          $ EdhError UsageError "Edh error object not changable"
          $ getEdhCallContext 0 pgs
  return $ EntityManipulater the'lookup'entity'attr
                             the'all'entity'attrs
                             the'change'entity'attr
                             the'update'entity'attrs


-- | Throw a tagged error from an Edh proc
--
-- a bit similar to `return` in Haskell, this doesn't cease the execution
-- of subsequent `EdhProc` actions following it, be cautious.
throwEdh :: EdhErrorTag -> Text -> EdhProc
throwEdh !et !msg = ask >>= \pgs -> contEdhSTM $ throwEdhSTM pgs et msg

-- | Throw a tagged error from the stm operation of an Edh proc
throwEdhSTM :: EdhProgState -> EdhErrorTag -> Text -> STM ()
throwEdhSTM !pgs !et !msg = getEdhErrClass pgs et >>= \ec ->
  runEdhProc pgs
    $ constructEdhObject ec (ArgsPack [EdhString msg] odEmpty)
    $ \(OriginalValue !exo _ _) -> ask >>= contEdhSTM . flip edhThrowSTM exo


-- | Throw arbitrary value from an Edh proc
--
-- a bit similar to `return` in Haskell, this doesn't cease the execution
-- of subsequent `EdhProc` actions following it, be cautious.
edhThrow :: EdhValue -> EdhProc
edhThrow !exv = ask >>= contEdhSTM . flip edhThrowSTM exv
edhThrowSTM :: EdhProgState -> EdhValue -> STM ()
edhThrowSTM !pgs !exv = do
  let propagateExc :: EdhValue -> [Scope] -> STM ()
      propagateExc exv' [] = edhErrorUncaught pgs exv'
      propagateExc exv' (frame : stack) =
        runEdhProc pgs $ exceptionHandler frame exv' $ \exv'' ->
          contEdhSTM $ propagateExc exv'' stack
  propagateExc exv $ NE.toList $ callStack $ edh'context pgs

edhErrorUncaught :: EdhProgState -> EdhValue -> STM ()
edhErrorUncaught !pgs !exv = case exv of
  EdhObject exo -> do
    esd <- readTVar $ entity'store $ objEntity exo
    case fromDynamic esd :: Maybe SomeException of
      Just !e -> -- TODO replace cc in err if is empty here ?
        throwSTM e
      Nothing -> edhValueReprSTM pgs exv
        $ \msg ->
        -- TODO support magic method to coerce as exception ?
                  throwSTM $ EdhError EvalError msg $ getEdhCallContext 0 pgs
  EdhString !msg -> throwSTM $ EdhError EvalError msg $ getEdhCallContext 0 pgs
  _              -> edhValueReprSTM pgs exv
    -- coerce arbitrary value to EdhError
    $ \msg -> throwSTM $ EdhError EvalError msg $ getEdhCallContext 0 pgs


-- | Catch possible throw from the specified try action
edhCatch
  :: (EdhProcExit -> EdhProc)
  -> EdhProcExit
  -> (  -- contextMatch of this proc will the thrown value or nil
        EdhProcExit  -- ^ recover exit
     -> EdhProc     -- ^ rethrow exit
     -> EdhProc
     )
  -> EdhProc
edhCatch !tryAct !exit !passOn = ask >>= \pgsOuter ->
  contEdhSTM
    $ edhCatchSTM pgsOuter
                  (\pgsTry exit' -> runEdhProc pgsTry (tryAct exit'))
                  exit
    $ \pgsThrower exv recover rethrow -> do
        let !ctxOuter = edh'context pgsOuter
            !ctxHndl  = ctxOuter { contextMatch = exv }
            !pgsHndl  = pgsThrower { edh'context = ctxHndl }
        runEdhProc pgsHndl $ passOn recover $ contEdhSTM rethrow
edhCatchSTM
  :: EdhProgState
  -> (EdhProgState -> EdhProcExit -> STM ())  -- ^ tryAct
  -> EdhProcExit
  -> (  EdhProgState -- ^ thrower's pgs, the task queue is important
     -> EdhValue     -- ^ exception value or nil
     -> EdhProcExit  -- ^ recover exit
     -> STM ()       -- ^ rethrow exit
     -> STM ()
     )
  -> STM ()
edhCatchSTM !pgsOuter !tryAct !exit !passOn = do
  hndlrTh <- unsafeIOToSTM myThreadId
  let
    !ctxOuter   = edh'context pgsOuter
    !scopeOuter = contextScope ctxOuter
    !tryScope   = scopeOuter { exceptionHandler = hndlr }
    !tryCtx = ctxOuter { callStack = tryScope :| NE.tail (callStack ctxOuter) }
    !pgsTry     = pgsOuter { edh'context = tryCtx }
    hndlr :: EdhExcptHndlr
    hndlr !exv !rethrow = do
      pgsThrower <- ask
      let goRecover :: EdhProcExit
          goRecover !result = ask >>= \pgs ->
            -- an exception handler provided another result value to recover
            contEdhSTM $ fromEdhError pgs exv $ \ex -> case fromException ex of
              Just ProgramHalt{} -> goRethrow -- never recover from ProgramHalt
              _                  -> do
                -- do recover from the exception
                rcvrTh <- unsafeIOToSTM myThreadId
                if rcvrTh /= hndlrTh
                  then -- just skip the action if from a different thread
                       return () -- other than the handler installer
                  else runEdhProc pgsOuter $ exit result
          goRethrow :: STM ()
          goRethrow =
            runEdhProc pgsThrower { edh'context = edh'context pgsOuter }
              $ exceptionHandler scopeOuter exv rethrow
      contEdhSTM $ passOn pgsThrower exv goRecover goRethrow
  tryAct pgsTry $ \tryResult -> contEdhSTM $ do
    -- no exception occurred, go trigger finally block
    rcvrTh <- unsafeIOToSTM myThreadId
    if rcvrTh /= hndlrTh
      then -- just skip the action if from a different thread
           return () -- other than the handler installer
      else
        passOn pgsOuter nil (error "bug: recovering from finally block")
          $ exitEdhSTM' pgsOuter exit tryResult


-- | Construct an Edh object from a class
constructEdhObject :: Class -> ArgsPack -> EdhProcExit -> EdhProc
constructEdhObject !cls apk@(ArgsPack !args !kwargs) !exit = do
  pgsCaller <- ask
  createEdhObject cls apk $ \(OriginalValue !thisVal _ _) -> case thisVal of
    EdhObject !this -> do
      let thisEnt     = objEntity this
          callerCtx   = edh'context pgsCaller
          callerScope = contextScope callerCtx
          initScope   = callerScope { thisObject  = this
                                    , thatObject  = this
                                    , scopeProc   = cls
                                    , scopeCaller = contextStmt callerCtx
                                    }
          ctorCtx = callerCtx { callStack = initScope <| callStack callerCtx
                              , contextExporting = False
                              , contextEffDefining = False
                              }
          pgsCtor = pgsCaller { edh'context = ctorCtx }
      contEdhSTM
        $   lookupEntityAttr pgsCtor thisEnt (AttrByName "__init__")
        >>= \case
              EdhNil ->
                if (null args && odNull kwargs) -- no ctor arg at all
                   || -- it's okay for a host class to omit __init__()
                        -- while processes ctor args by the host class proc
                      isRight (procedure'body $ procedure'decl cls)
                then
                  exitEdhSTM pgsCaller exit thisVal
                else
                  throwEdhSTM pgsCaller EvalError
                  $  "No __init__() defined by class "
                  <> procedureName cls
                  <> " to receive argument(s)"
              EdhMethod !initMth ->
                case procedure'body $ procedure'decl initMth of
                  Right !hp ->
                    runEdhProc pgsCtor
                      $ hp apk
                      $ \(OriginalValue !hostInitRtn _ _) ->
                          -- a host __init__() method is responsible to return new
                          -- `this` explicitly, or another value as appropriate
                          contEdhSTM $ exitEdhSTM pgsCaller exit hostInitRtn
                  Left !pb ->
                    runEdhProc pgsCaller
                      $ local (const pgsCtor)
                      $ callEdhMethod' Nothing this initMth pb apk id
                      $ \(OriginalValue !initRtn _ _) ->
                          local (const pgsCaller) $ case initRtn of
                              -- allow a __init__() procedure to explicitly return other
                              -- value than newly constructed `this` object
                              -- it can still `return this` to early stop the proc
                              -- which is magically an advanced feature
                            EdhReturn !rtnVal -> exitEdhProc exit rtnVal
                            EdhContinue       -> throwEdh
                              EvalError
                              "Unexpected continue from __init__()"
                            -- allow the use of `break` to early stop a __init__() 
                            -- procedure with nil result
                            EdhBreak -> exitEdhProc exit nil
                            -- no explicit return from __init__() procedure, return the
                            -- newly constructed this object, throw away the last
                            -- value from the procedure execution
                            _        -> exitEdhProc exit thisVal
              badInitMth ->
                throwEdhSTM pgsCaller EvalError
                  $  "Invalid __init__() method type from class - "
                  <> T.pack (edhTypeNameOf badInitMth)
    _ -> -- return whatever the constructor returned if not an object
      exitEdhProc exit thisVal

-- | Creating an Edh object from a class, without calling its `__init__()` method
createEdhObject :: Class -> ArgsPack -> EdhProcExit -> EdhProc
createEdhObject !cls !apk !exit = do
  pgsCaller <- ask
  let !callerCtx   = edh'context pgsCaller
      !callerScope = contextScope callerCtx
  case procedure'body $ procedure'decl cls of

    -- calling a host class (constructor) procedure
    Right !hp -> contEdhSTM $ do
      -- note: cross check logic here with `mkHostClass`
      -- the host ctor procedure is responsible for instance creation, so the
      -- scope entiy, `this` and `that` are not changed for its call frame
      let !calleeScope =
            callerScope { scopeProc = cls, scopeCaller = contextStmt callerCtx }
          !calleeCtx = callerCtx
            { callStack          = calleeScope <| callStack callerCtx
            , generatorCaller    = Nothing
            , contextMatch       = true
            , contextPure        = False
            , contextExporting   = False
            , contextEffDefining = False
            }
          !pgsCallee = pgsCaller { edh'context = calleeCtx }
      runEdhProc pgsCallee $ hp apk $ \(OriginalValue !val _ _) ->
        contEdhSTM $ exitEdhSTM pgsCaller exit val

    -- calling an Edh namespace/class (constructor) procedure
    Left !pb -> contEdhSTM $ do
      newEnt  <- createHashEntity =<< iopdEmpty
      newThis <- viewAsEdhObject newEnt cls []
      let
        goCtor = do
          let !ctorScope = objectScope callerCtx newThis
              !ctorCtx   = callerCtx
                { callStack          = ctorScope <| callStack callerCtx
                , generatorCaller    = Nothing
                , contextMatch       = true
                , contextPure        = False
                , contextStmt        = pb
                , contextExporting   = False
                , contextEffDefining = False
                }
              !pgsCtor = pgsCaller { edh'context = ctorCtx }
          runEdhProc pgsCtor $ evalStmt pb $ \(OriginalValue !ctorRtn _ _) ->
            local (const pgsCaller) $ case ctorRtn of
              -- allow a class procedure to explicitly return other
              -- value than newly constructed `this` object
              -- it can still `return this` to early stop the proc
              -- which is magically an advanced feature
              EdhReturn !rtnVal -> exitEdhProc exit rtnVal
              EdhContinue ->
                throwEdh EvalError "Unexpected continue from constructor"
              -- allow the use of `break` to early stop a constructor 
              -- procedure with nil result
              EdhBreak -> exitEdhProc exit nil
              -- no explicit return from class procedure, return the
              -- newly constructed this object, throw away the last
              -- value from the procedure execution
              _        -> exitEdhProc exit (EdhObject newThis)
      case procedure'args $ procedure'decl cls of
        -- a namespace procedure, should pass ctor args to it
        WildReceiver -> do
          let !recvCtx = callerCtx
                { callStack = (lexicalScopeOf cls) { thisObject = newThis
                                                   , thatObject = newThis
                                                   }
                                :| []
                , generatorCaller    = Nothing
                , contextMatch       = true
                , contextPure        = False
                , contextStmt        = pb
                , contextExporting   = False
                , contextEffDefining = False
                }
          runEdhProc pgsCaller $ recvEdhArgs recvCtx WildReceiver apk $ \oed ->
            contEdhSTM $ do
              updateEntityAttrs pgsCaller (objEntity newThis) $ odToList oed
              goCtor
        -- a class procedure, should leave ctor args for its __init__ method
        PackReceiver [] -> goCtor
        _               -> error "bug: imposible constructor procedure args"


callEdhOperator
  :: Object
  -> ProcDefi
  -> Maybe EdhValue
  -> [EdhValue]
  -> EdhProcExit
  -> EdhProc
callEdhOperator !mth'that !mth'proc !prede !args !exit = do
  pgsCaller <- ask
  let callerCtx   = edh'context pgsCaller
      callerScope = contextScope callerCtx
  case procedure'body $ procedure'decl mth'proc of

    -- calling a host operator procedure
    Right !hp -> do
      -- a host procedure views the same scope entity as of the caller's
      -- call frame
      let !mthScope = (lexicalScopeOf mth'proc) { scopeEntity = scopeEntity
                                                  callerScope
                                                , thatObject  = mth'that
                                                , scopeProc   = mth'proc
                                                , scopeCaller = contextStmt
                                                  callerCtx
                                                }
          !mthCtx = callerCtx { callStack = mthScope <| callStack callerCtx
                              , generatorCaller    = Nothing
                              , contextMatch       = true
                              , contextPure        = False
                              , contextExporting   = False
                              , contextEffDefining = False
                              }
          !pgsMth = pgsCaller { edh'context = mthCtx }
      -- push stack for the host procedure
      local (const pgsMth)
        $ hp (ArgsPack args odEmpty)
        $ \(OriginalValue !val _ _) ->
        -- pop stack after host procedure returned
        -- return whatever the result a host procedure returned
            contEdhSTM $ exitEdhSTM pgsCaller exit val

    -- calling an Edh operator procedure
    Left !pb ->
      callEdhOperator' Nothing mth'that mth'proc prede pb args
        $ \(OriginalValue !mthRtn _ _) -> case mthRtn of
            -- allow continue to be return from a operator proc,
            -- to carry similar semantics like `NotImplemented` in Python
            EdhContinue      -> exitEdhProc exit EdhContinue
            -- allow the use of `break` to early stop a operator 
            -- procedure with nil result
            EdhBreak         -> exitEdhProc exit nil
            -- explicit return
            EdhReturn rtnVal -> exitEdhProc exit rtnVal
            -- no explicit return, assuming it returns the last
            -- value from procedure execution
            _                -> exitEdhProc exit mthRtn

callEdhOperator'
  :: Maybe EdhGenrCaller
  -> Object
  -> ProcDefi
  -> Maybe EdhValue
  -> StmtSrc
  -> [EdhValue]
  -> EdhProcExit
  -> EdhProc
callEdhOperator' !gnr'caller !callee'that !mth'proc !prede !mth'body !args !exit
  = do
    !pgsCaller <- ask
    let !callerCtx = edh'context pgsCaller
        !recvCtx   = callerCtx
          { callStack = (lexicalScopeOf mth'proc) { thatObject = callee'that }
                          :| []
          , generatorCaller    = Nothing
          , contextMatch       = true
          , contextStmt        = mth'body
          , contextPure        = False
          , contextExporting   = False
          , contextEffDefining = False
          }
    recvEdhArgs recvCtx
                (procedure'args $ procedure'decl mth'proc)
                (ArgsPack args odEmpty)
      $ \ !ed -> contEdhSTM $ do
          ent <- createHashEntity =<< iopdFromList (odToList ed)
          let !mthScope = (lexicalScopeOf mth'proc) { scopeEntity = ent
                                                    , thatObject  = callee'that
                                                    , scopeProc   = mth'proc
                                                    , scopeCaller = contextStmt
                                                      callerCtx
                                                    }
              !mthCtx = callerCtx { callStack = mthScope <| callStack callerCtx
                                  , generatorCaller    = gnr'caller
                                  , contextMatch       = true
                                  , contextStmt        = mth'body
                                  , contextPure        = False
                                  , contextExporting   = False
                                  , contextEffDefining = False
                                  }
              !pgsMth = pgsCaller { edh'context = mthCtx }
          case prede of
            Nothing -> pure ()
            -- put the overridden predecessor operator in scope of the overriding
            -- op proc's run ctx
            Just !predOp ->
              changeEntityAttr pgsMth ent (procedure'name mth'proc) predOp
          -- push stack for the Edh procedure
          runEdhProc pgsMth
            $ evalStmt mth'body
            $ \(OriginalValue !mthRtn _ _) ->
            -- pop stack after Edh procedure returned
                local (const pgsCaller) $ exitEdhProc exit mthRtn


callEdhMethod
  :: Object
  -> ProcDefi
  -> ArgsPack
  -> (Scope -> Scope)
  -> EdhProcExit
  -> EdhProc
callEdhMethod !mth'that !mth'proc !apk !scopeMod !exit = do
  pgsCaller <- ask
  let callerCtx   = edh'context pgsCaller
      callerScope = contextScope callerCtx
  case procedure'body $ procedure'decl mth'proc of

    -- calling a host method procedure
    Right !hp -> do
      -- a host procedure views the same scope entity as of the caller's
      -- call frame
      let !mthScope = scopeMod $ (lexicalScopeOf mth'proc)
            { scopeEntity = scopeEntity callerScope
            , thatObject  = mth'that
            , scopeProc   = mth'proc
            , scopeCaller = contextStmt callerCtx
            }
          !mthCtx = callerCtx { callStack = mthScope <| callStack callerCtx
                              , generatorCaller    = Nothing
                              , contextMatch       = true
                              , contextPure        = False
                              , contextExporting   = False
                              , contextEffDefining = False
                              }
          !pgsMth = pgsCaller { edh'context = mthCtx }
      -- push stack for the host procedure
      local (const pgsMth) $ hp apk $ \(OriginalValue !val _ _) ->
        -- pop stack after host procedure returned
        -- return whatever the result a host procedure returned
        contEdhSTM $ exitEdhSTM pgsCaller exit val

    -- calling an Edh method procedure
    Left !pb ->
      callEdhMethod' Nothing mth'that mth'proc pb apk scopeMod
        $ \(OriginalValue !mthRtn _ _) -> case mthRtn of
            -- allow continue to be return from a method proc,
            -- to carry similar semantics like `NotImplemented` in Python
            EdhContinue      -> exitEdhProc exit EdhContinue
            -- allow the use of `break` to early stop a method 
            -- procedure with nil result
            EdhBreak         -> exitEdhProc exit nil
            -- explicit return
            EdhReturn rtnVal -> exitEdhProc exit rtnVal
            -- no explicit return, assuming it returns the last
            -- value from procedure execution
            _                -> exitEdhProc exit mthRtn

callEdhMethod'
  :: Maybe EdhGenrCaller
  -> Object
  -> ProcDefi
  -> StmtSrc
  -> ArgsPack
  -> (Scope -> Scope)
  -> EdhProcExit
  -> EdhProc
callEdhMethod' !gnr'caller !callee'that !mth'proc !mth'body !apk !scopeMod !exit
  = do
    !pgsCaller <- ask
    let !callerCtx = edh'context pgsCaller
        !recvCtx   = callerCtx
          { callStack = (lexicalScopeOf mth'proc) { thatObject = callee'that }
                          :| []
          , generatorCaller    = Nothing
          , contextMatch       = true
          , contextStmt        = mth'body
          , contextPure        = False
          , contextExporting   = False
          , contextEffDefining = False
          }
    recvEdhArgs recvCtx (procedure'args $ procedure'decl mth'proc) apk $ \ed ->
      contEdhSTM $ do
        ent <- createHashEntity =<< iopdFromList (odToList ed)
        let !mthScope = scopeMod $ (lexicalScopeOf mth'proc)
              { scopeEntity = ent
              , thatObject  = callee'that
              , scopeProc   = mth'proc
              , scopeCaller = contextStmt callerCtx
              }
            !mthCtx = callerCtx { callStack = mthScope <| callStack callerCtx
                                , generatorCaller    = gnr'caller
                                , contextMatch       = true
                                , contextStmt        = mth'body
                                , contextPure        = False
                                , contextExporting   = False
                                , contextEffDefining = False
                                }
            !pgsMth = pgsCaller { edh'context = mthCtx }
        -- push stack for the Edh procedure
        runEdhProc pgsMth $ evalStmt mth'body $ \(OriginalValue !mthRtn _ _) ->
          -- pop stack after Edh procedure returned
          local (const pgsCaller) $ exitEdhProc exit mthRtn


edhForLoop
  :: EdhProgState
  -> ArgsReceiver
  -> Expr
  -> Expr
  -> (EdhValue -> STM ())
  -> ((EdhProcExit -> EdhProc) -> STM ())
  -> STM ()
edhForLoop !pgsLooper !argsRcvr !iterExpr !doExpr !iterCollector !forLooper =
  do
    let
        -- receive one yielded value from the generator, the 'genrCont' here is
        -- to continue the generator execution, result passed to the 'genrCont'
        -- here is the eval'ed value of the `yield` expression from the
        -- generator's perspective, or exception to be thrown from there
      recvYield
        :: EdhProcExit
        -> EdhValue
        -> (Either (EdhProgState, EdhValue) EdhValue -> STM ())
        -> EdhProc
      recvYield !exit !yielded'val !genrCont = do
        pgs <- ask
        let
          !ctx   = edh'context pgs
          !scope = contextScope ctx
          doOne !pgsTry !exit' =
            runEdhProc pgsTry
              $ recvEdhArgs
                  (edh'context pgsTry)
                  argsRcvr
                  (case yielded'val of
                    EdhArgsPack apk -> apk
                    _               -> ArgsPack [yielded'val] odEmpty
                  )
              $ \em -> contEdhSTM $ do
                  updateEntityAttrs pgsTry (scopeEntity scope) $ odToList em
                  runEdhProc pgsTry $ evalExpr doExpr exit'
          doneOne (OriginalValue !doResult _ _) =
            case edhDeCaseClose doResult of
              EdhContinue ->
                -- send nil to generator on continue
                contEdhSTM $ genrCont $ Right nil
              EdhBreak ->
                -- break out of the for-from-do loop,
                -- the generator on <break> yielded will return
                -- nil, effectively have the for loop eval to nil
                contEdhSTM $ genrCont $ Right EdhBreak
              EdhCaseOther ->
                -- send nil to generator on no-match of a branch
                contEdhSTM $ genrCont $ Right nil
              EdhFallthrough ->
                -- send nil to generator on fallthrough
                contEdhSTM $ genrCont $ Right nil
              EdhReturn EdhReturn{} -> -- this has special meaning
                -- Edh code should not use this pattern
                throwEdh UsageError "double return from do-of-for?"
              EdhReturn !rtnVal ->
                -- early return from for-from-do, the geneerator on
                -- double wrapped return yielded, will unwrap one
                -- level and return the result, effectively have the
                -- for loop eval to return that 
                contEdhSTM $ genrCont $ Right $ EdhReturn $ EdhReturn rtnVal
              !val -> contEdhSTM $ do
                -- vanilla val from do, send to generator
                iterCollector val
                genrCont $ Right val
        case yielded'val of
          EdhNil -> -- nil yielded from a generator effectively early stops
            exitEdhProc exit nil
          EdhContinue -> throwEdh EvalError "generator yielded continue"
          EdhBreak    -> throwEdh EvalError "generator yielded break"
          EdhReturn{} -> throwEdh EvalError "generator yielded return"
          _ ->
            contEdhSTM
              $ edhCatchSTM pgs doOne doneOne
              $ \ !pgsThrower !exv _recover rethrow -> case exv of
                  EdhNil -> rethrow -- no exception occurred in do block
                  _ -> -- exception uncaught in do block
                    -- propagate to the generator, the genr may catch it or 
                    -- the exception will propagate to outer of for-from-do
                    genrCont $ Left (pgsThrower, exv)

    runEdhProc pgsLooper $ case deParen iterExpr of
      CallExpr !procExpr !argsSndr -> -- loop over a generator
        contEdhSTM
          $ resolveEdhCallee pgsLooper procExpr
          $ \(OriginalValue !callee'val _ !callee'that, scopeMod) ->
              runEdhProc pgsLooper $ case callee'val of

                -- calling a generator
                (EdhGnrtor !gnr'proc) -> packEdhArgs argsSndr $ \apk ->
                  case procedure'body $ procedure'decl gnr'proc of

                    -- calling a host generator
                    Right !hp -> contEdhSTM $ forLooper $ \exit -> do
                      pgs <- ask
                      let !ctx   = edh'context pgs
                          !scope = contextScope ctx
                      contEdhSTM $ do
                        -- a host procedure views the same scope entity as of the caller's
                        -- call frame
                        let !calleeScope = (lexicalScopeOf gnr'proc)
                              { scopeEntity = scopeEntity scope
                              , thatObject  = callee'that
                              , scopeProc   = gnr'proc
                              , scopeCaller = contextStmt ctx
                              }
                            !calleeCtx = ctx
                              { callStack = calleeScope <| callStack ctx
                              , generatorCaller    = Just (pgs, recvYield exit)
                              , contextMatch       = true
                              , contextPure        = False
                              , contextExporting   = False
                              , contextEffDefining = False
                              }
                            !pgsCallee = pgs { edh'context = calleeCtx }
                        -- insert a cycle tick here, so if no tx required for the call
                        -- overall, the callee resolution tx stops here then the callee
                        -- runs in next stm transaction
                        flip (exitEdhSTM' pgsCallee) (wuji pgsCallee) $ \_ ->
                          hp apk $ \(OriginalValue val _ _) ->
                            -- return the result in CPS with caller pgs restored
                            contEdhSTM $ exitEdhSTM pgsLooper exit val

                    -- calling an Edh generator
                    Left !pb -> contEdhSTM $ forLooper $ \exit -> do
                      pgs <- ask
                      callEdhMethod' (Just (pgs, recvYield exit))
                                     callee'that
                                     gnr'proc
                                     pb
                                     apk
                                     scopeMod
                        $ \(OriginalValue !gnrRtn _ _) -> case gnrRtn of
                            -- return the result in CPS with looper pgs restored
                            EdhContinue ->
                              -- propagate the continue from generator return
                              contEdhSTM $ exitEdhSTM pgsLooper exit EdhContinue
                            EdhBreak ->
                              -- todo what's the case a generator would break out?
                              contEdhSTM $ exitEdhSTM pgsLooper exit nil
                            EdhReturn !rtnVal -> -- it'll be double return, in
                              -- case do block issued return and propagated here
                              -- or the generator can make it that way, which is
                              -- black magic
                              -- unwrap the return, as result of this for-loop 
                              contEdhSTM $ exitEdhSTM pgsLooper exit rtnVal
                            -- otherwise passthrough
                            _ -> contEdhSTM $ exitEdhSTM pgsLooper exit gnrRtn

                -- calling other procedures, assume to loop over its return value
                _ ->
                  contEdhSTM
                    $ edhMakeCall pgsLooper
                                  callee'val
                                  callee'that
                                  argsSndr
                                  scopeMod
                    $ \mkCall ->
                        runEdhProc pgsLooper
                          $ mkCall
                          $ \(OriginalValue !iterVal _ _) ->
                              loopOverValue iterVal

      _ -> -- loop over an iterable value
           evalExpr iterExpr $ \(OriginalValue !iterVal _ _) ->
        loopOverValue $ edhDeCaseClose iterVal

 where

  loopOverValue :: EdhValue -> EdhProc
  loopOverValue !iterVal = contEdhSTM $ forLooper $ \exit -> do
    pgs <- ask
    let !ctx   = edh'context pgs
        !scope = contextScope ctx
    contEdhSTM $ do
      let -- do one iteration
          do1 :: ArgsPack -> STM () -> STM ()
          do1 !apk !next =
            runEdhProc pgs $ recvEdhArgs ctx argsRcvr apk $ \em ->
              contEdhSTM $ do
                updateEntityAttrs pgs (scopeEntity scope) $ odToList em
                runEdhProc pgs
                  $ evalExpr doExpr
                  $ \(OriginalValue !doResult _ _) -> case doResult of
                      EdhBreak ->
                        -- break for loop
                        exitEdhProc exit nil
                      rtn@EdhReturn{} ->
                        -- early return during for loop
                        exitEdhProc exit rtn
                      _ -> contEdhSTM $ do
                        -- continue for loop
                        iterCollector doResult
                        next

          -- loop over a series of args packs
          iterThem :: [ArgsPack] -> STM ()
          iterThem []           = exitEdhSTM pgs exit nil
          iterThem (apk : apks) = do1 apk $ iterThem apks

          -- loop over a subscriber's channel of an event sink
          iterEvt :: TChan EdhValue -> STM ()
          iterEvt !subChan = edhPerformSTM pgs (readTChan subChan) $ \case
            EdhNil -> -- nil marks end-of-stream from an event sink
              exitEdhProc exit nil -- stop the for-from-do loop
            EdhArgsPack apk -> contEdhSTM $ do1 apk $ iterEvt subChan
            v -> contEdhSTM $ do1 (ArgsPack [v] odEmpty) $ iterEvt subChan

      case edhUltimate iterVal of

        -- loop from an event sink
        (EdhSink sink) -> subscribeEvents sink >>= \(subChan, mrv) ->
          case mrv of
            Nothing -> iterEvt subChan
            Just ev -> case ev of
              EdhNil -> -- this sink is already marked at end-of-stream
                exitEdhSTM pgs exit nil
              EdhArgsPack apk -> do1 apk $ iterEvt subChan
              v               -> do1 (ArgsPack [v] odEmpty) $ iterEvt subChan

        -- loop from a positonal-only args pack
        (EdhArgsPack (ArgsPack !args !kwargs)) | odNull kwargs -> iterThem
          [ case val of
              EdhArgsPack apk' -> apk'
              _                -> ArgsPack [val] odEmpty
          | val <- args
          ]

        -- loop from a keyword-only args pack
        (EdhArgsPack (ArgsPack !args !kwargs)) | null args -> iterThem
          [ ArgsPack [attrKeyValue k, v] odEmpty | (k, v) <- odToList kwargs ]

        -- loop from a list
        (EdhList (List _ !l)) -> do
          ll <- readTVar l
          iterThem
            [ case val of
                EdhArgsPack apk' -> apk'
                _                -> ArgsPack [val] odEmpty
            | val <- ll
            ]

        -- loop from a dict
        (EdhDict (Dict _ !d)) -> do
          del <- iopdToList d
          -- don't be tempted to yield pairs from a dict here,
          -- it'll be messy if some entry values are themselves pairs
          iterThem [ ArgsPack [k, v] odEmpty | (k, v) <- del ]

        -- TODO define the magic method for an object to be able to respond
        --      to for-from-do looping

        _ ->
          throwEdhSTM pgsLooper EvalError
            $  "Can not do a for loop from "
            <> T.pack (edhTypeNameOf iterVal)
            <> ": "
            <> T.pack (show iterVal)


-- | Create a reflective object capturing the specified scope as from the
-- specified context
--
-- the contextStmt is captured as the procedure body of its fake class
--
-- todo currently only lexical context is recorded, the call frames may
--      be needed in the future
mkScopeWrapper :: Context -> Scope -> STM Object
mkScopeWrapper !ctx !scope = do
  -- a scope wrapper object is itself a mao object, no attr at all
  wrapperEnt <- createMaoEntity
  -- 'scopeSuper' provides the builtin scope manipulation methods
  viewAsEdhObject wrapperEnt wrapperClass [scopeSuper world]
 where
  !world        = contextWorld ctx
  !wrapperClass = (objClass $ scopeSuper world)
    { procedure'lexi = Just scope
    , procedure'decl = procedure'decl $ scopeProc scope
    }

isScopeWrapper :: Context -> Object -> STM Bool
isScopeWrapper !ctx !o = do
  supers <- readTVar (objSupers o)
  return $ elem (scopeSuper world) supers
  where !world = contextWorld ctx

-- | Get the wrapped scope from a wrapper object
wrappedScopeOf :: Object -> Scope
wrappedScopeOf !sw = case procedure'lexi $ objClass sw of
  Just !scope -> scope
  Nothing     -> error "bug: wrapped scope lost"


-- | Assign an evaluated value to a target expression
--
-- Note the calling procedure should declare in-tx state in evaluating the
-- right-handle value as well as running this, so the evaluation of the
-- right-hand value as well as the writting to the target entity are done
-- within the same tx, thus for atomicity of the whole assignment.
assignEdhTarget :: EdhProgState -> Expr -> EdhProcExit -> EdhValue -> EdhProc
assignEdhTarget !pgsAfter !lhExpr !exit !rhVal = do
  !pgs <- ask
  let !ctx  = edh'context pgs
      scope = contextScope ctx
      this  = thisObject scope
      that  = thatObject scope
      exitWithChkExportTo :: Entity -> AttrKey -> EdhValue -> STM ()
      exitWithChkExportTo !ent !artKey !artVal = do
        when (contextExporting ctx)
          $   lookupEntityAttr pgs ent (AttrByName edhExportsMagicName)
          >>= \case
                EdhDict (Dict _ !thisExpDS) ->
                  iopdInsert (attrKeyValue artKey) artVal thisExpDS
                _ -> do
                  d <- createEdhDict [(attrKeyValue artKey, artVal)]
                  changeEntityAttr pgs
                                   (objEntity this)
                                   (AttrByName edhExportsMagicName)
                                   d
        runEdhProc pgsAfter $ exitEdhProc exit artVal
      defEffectInto :: Entity -> AttrKey -> STM ()
      defEffectInto !ent !artKey =
        lookupEntityAttr pgs ent (AttrByName edhEffectsMagicName) >>= \case
          EdhDict (Dict _ !effDS) ->
            iopdInsert (attrKeyValue artKey) rhVal effDS
          _ -> do
            d <- createEdhDict [(attrKeyValue artKey, rhVal)]
            changeEntityAttr pgs ent (AttrByName edhEffectsMagicName) d
  case lhExpr of
    AttrExpr !addr -> case addr of
      -- silently drop value assigned to single underscore
      DirectRef (NamedAttr "_") ->
        contEdhSTM $ runEdhProc pgsAfter $ exitEdhProc exit nil
      -- no magic imposed to direct assignment in a (possibly class) proc
      DirectRef !addr' -> contEdhSTM $ resolveEdhAttrAddr pgs addr' $ \key ->
        do
          if contextEffDefining ctx
            then defEffectInto (scopeEntity scope) key
            else changeEntityAttr pgs (scopeEntity scope) key rhVal
          exitWithChkExportTo (objEntity this) key rhVal
      -- special case, assigning with `this.v=x` `that.v=y`, handle exports and
      -- effect definition
      IndirectRef (AttrExpr ThisRef) addr' ->
        contEdhSTM $ resolveEdhAttrAddr pgs addr' $ \key -> do
          let !thisEnt = objEntity this
          if contextEffDefining ctx
            then do
              defEffectInto thisEnt key
              exitWithChkExportTo thisEnt key rhVal
            else changeEdhObjAttr pgs this key rhVal
              $ \ !valSet -> exitWithChkExportTo thisEnt key valSet
      IndirectRef (AttrExpr ThatRef) addr' ->
        contEdhSTM $ resolveEdhAttrAddr pgs addr' $ \key -> do
          let !thatEnt = objEntity $ thatObject scope
          if contextEffDefining ctx
            then do
              defEffectInto thatEnt key
              exitWithChkExportTo thatEnt key rhVal
            else changeEdhObjAttr pgs that key rhVal
              $ \ !valSet -> exitWithChkExportTo thatEnt key valSet
      -- assign to an addressed attribute
      IndirectRef !tgtExpr !addr' ->
        contEdhSTM $ resolveEdhAttrAddr pgs addr' $ \key ->
          runEdhProc pgs $ setEdhAttr pgsAfter tgtExpr key rhVal exit
      -- god forbidden things
      ThisRef  -> throwEdh EvalError "Can not assign to this"
      ThatRef  -> throwEdh EvalError "Can not assign to that"
      SuperRef -> throwEdh EvalError "Can not assign to super"
    -- dereferencing attribute assignment
    InfixExpr "@" !tgtExpr !addrRef ->
      evalExpr addrRef $ \(OriginalValue !addrVal _ _) ->
        case edhUltimate addrVal of
          EdhExpr _ (AttrExpr (DirectRef !addr)) _ ->
            contEdhSTM $ resolveEdhAttrAddr pgs addr $ \key ->
              runEdhProc pgs $ setEdhAttr pgsAfter tgtExpr key rhVal exit
          EdhString !attrName ->
            setEdhAttr pgsAfter tgtExpr (AttrByName attrName) rhVal exit
          EdhSymbol !sym ->
            setEdhAttr pgsAfter tgtExpr (AttrBySym sym) rhVal exit
          _ ->
            throwEdh EvalError $ "Invalid attribute reference type - " <> T.pack
              (edhTypeNameOf addrVal)
    x ->
      throwEdh EvalError
        $  "Invalid left hand expression for assignment: "
        <> T.pack (show x)


changeEdhObjAttr
  :: EdhProgState
  -> Object
  -> AttrKey
  -> EdhValue
  -> (EdhValue -> STM ())
  -> STM ()
changeEdhObjAttr !pgs !obj !key !val !exit =
  -- don't shadow overwriting to a directly existing attr
  lookupEntityAttr pgs (objEntity obj) key >>= \case
    EdhNil -> lookupEntityAttr pgs (objEntity obj) (AttrByName "@=") >>= \case
      EdhNil ->
        -- normal attr lookup with supers involved
        lookupEdhObjAttr pgs obj key >>= chkProperty
      EdhMethod !mth ->
        -- call magic (@=) method
        runEdhProc pgs
          $ callEdhMethod obj mth (ArgsPack [attrKeyValue key, val] odEmpty) id
          $ \(OriginalValue !rtnVal _ _) -> contEdhSTM $ exit rtnVal
      !badMth ->
        throwEdhSTM pgs UsageError $ "Malformed magic (@=) method of " <> T.pack
          (edhTypeNameOf badMth)
    !existingVal ->
      -- a directly existing attr, bypassed magic (@=) method
      chkProperty existingVal
 where
  chkProperty = \case
    EdhDescriptor !getter Nothing ->
      throwEdhSTM pgs UsageError
        $  "Property "
        <> T.pack (show $ procedure'name getter)
        <> " is readonly"
    EdhDescriptor _ (Just !setter) ->
      let !args = case val of
            EdhNil -> []
            _      -> [val]
      in  runEdhProc pgs
            $ callEdhMethod obj setter (ArgsPack args odEmpty) id
            $ \(OriginalValue !propRtn _ _) -> contEdhSTM $ exit propRtn
    _ -> do
      changeEntityAttr pgs (objEntity obj) key val
      exit val


-- The Edh call convention is so called call-by-repacking, i.e. a new pack of
-- arguments are evaluated & packed at the calling site, then passed to the
-- callee site, where arguments in the pack are received into an entity to be
-- used as the run-scope of the callee, the receiving may include re-packing
-- into attributes manifested for rest-args. For any argument mentioned by
-- the callee but missing from the pack from the caller, the call should fail
-- if the callee did not specify a default expr for the missing arg; if the
-- callee did have a default expr specified, the default expr should be eval'ed
-- in the callee's lexial context to provide the missing value into the entity
-- with attr name of that arg.

-- This is semantically much the same as Python's call convention, regarding
-- positional and keyword argument matching, in addition with the following:
--  * wildcard receiver - receive all keyword arguments into the entity
--  * retargeting - don't receive the argument into the entity, but assign
--    to an attribute of another object, typically `this` object in scope
--  * argument renaming - match the name as sent, receive to a differently
--     named attribute of the entity. while renaming a positional argument
--     is doable but meaningless, you'd just use the later name for the arg
--  * rest-args repacking, in forms of:
--     *args
--     **kwargs
--     ***apk


recvEdhArgs
  :: Context
  -> ArgsReceiver
  -> ArgsPack
  -> (OrderedDict AttrKey EdhValue -> EdhProc)
  -> EdhProc
recvEdhArgs !recvCtx !argsRcvr apk@(ArgsPack !posArgs !kwArgs) !exit = do
  !pgsCaller <- ask
  let -- args receive always done in callee's context with tx on
    !pgsRecv = pgsCaller { edh'in'tx = True, edh'context = recvCtx }
    recvFromPack
      :: ArgsPack
      -> IOPD AttrKey EdhValue
      -> ArgReceiver
      -> (ArgsPack -> STM ())
      -> STM ()
    recvFromPack pk@(ArgsPack !posArgs' !kwArgs') !em !argRcvr !exit' =
      case argRcvr of
        RecvRestPosArgs "_" ->
          -- silently drop the value to single underscore, while consume the args
          -- from incoming pack
          exit' (ArgsPack [] kwArgs')
        RecvRestPosArgs !restPosArgAttr -> do
          iopdInsert (AttrByName restPosArgAttr)
                     (EdhArgsPack $ ArgsPack posArgs' odEmpty)
                     em
          exit' (ArgsPack [] kwArgs')
        RecvRestKwArgs "_" ->
          -- silently drop the value to single underscore, while consume the args
          -- from incoming pack
          exit' (ArgsPack posArgs' odEmpty)
        RecvRestKwArgs restKwArgAttr -> if T.null restKwArgAttr
          then do
            iopdUpdate (odToList kwArgs') em
            exit' (ArgsPack posArgs' odEmpty)
          else do
            iopdInsert (AttrByName restKwArgAttr)
                       (EdhArgsPack $ ArgsPack [] kwArgs')
                       em
            exit' (ArgsPack posArgs' odEmpty)
        RecvRestPkArgs "_" ->
          -- silently drop the value to single underscore, while consume the args
          -- from incoming pack
          exit' (ArgsPack [] odEmpty)
        RecvRestPkArgs restPkArgAttr -> do
          iopdInsert (AttrByName restPkArgAttr) (EdhArgsPack pk) em
          exit' (ArgsPack [] odEmpty)
        RecvArg (NamedAttr "_") _ _ ->
          -- silently drop the value to single underscore, while consume the arg
          -- from incoming pack
          resolveArgValue (AttrByName "_") Nothing
            $ \(_, posArgs'', kwArgs'') -> exit' (ArgsPack posArgs'' kwArgs'')
        RecvArg !argAddr !argTgtAddr !argDefault ->
          resolveEdhAttrAddr pgsRecv argAddr $ \argKey ->
            resolveArgValue argKey argDefault
              $ \(argVal, posArgs'', kwArgs'') -> case argTgtAddr of
                  Nothing -> do
                    iopdInsert argKey argVal em
                    exit' (ArgsPack posArgs'' kwArgs'')
                  Just (DirectRef addr) -> case addr of
                    NamedAttr "_" -> -- drop
                      exit' (ArgsPack posArgs'' kwArgs'')
                    NamedAttr attrName -> do -- simple rename
                      iopdInsert (AttrByName attrName) argVal em
                      exit' (ArgsPack posArgs'' kwArgs'')
                    SymbolicAttr symName -> -- todo support this ?
                      throwEdhSTM pgsRecv UsageError
                        $  "Do you mean `this.@"
                        <> symName
                        <> "` instead ?"
                  Just addr@(IndirectRef _ _) -> do
                    -- do assignment in callee's context, and return to caller's afterwards
                    runEdhProc pgsRecv $ assignEdhTarget pgsCaller
                                                         (AttrExpr addr)
                                                         edhEndOfProc
                                                         argVal
                    exit' (ArgsPack posArgs'' kwArgs'')
                  tgt ->
                    throwEdhSTM pgsRecv UsageError
                      $  "Invalid argument retarget: "
                      <> T.pack (show tgt)
     where
      resolveArgValue
        :: AttrKey
        -> Maybe Expr
        -> (  (EdhValue, [EdhValue], OrderedDict AttrKey EdhValue)
           -> STM ()
           )
        -> STM ()
      resolveArgValue !argKey !argDefault !exit'' = do
        let (inKwArgs, kwArgs'') = odTakeOut argKey kwArgs'
        case inKwArgs of
          Just argVal -> exit'' (argVal, posArgs', kwArgs'')
          _           -> case posArgs' of
            (posArg : posArgs'') -> exit'' (posArg, posArgs'', kwArgs'')
            []                   -> case argDefault of
              Just defaultExpr -> do
                defaultVar <- newEmptyTMVar
                -- always eval the default value atomically in callee's contex
                runEdhProc pgsRecv $ evalExpr
                  defaultExpr
                  (\(OriginalValue !val _ _) ->
                    contEdhSTM (putTMVar defaultVar $ edhDeCaseClose val)
                  )
                defaultVal <- readTMVar defaultVar
                exit'' (defaultVal, posArgs', kwArgs'')
              _ ->
                throwEdhSTM pgsCaller UsageError
                  $  "Missing argument: "
                  <> T.pack (show argKey)
    woResidual :: ArgsPack -> STM () -> STM ()
    woResidual (ArgsPack !posResidual !kwResidual) !exit'
      | not (null posResidual)
      = throwEdhSTM pgsCaller UsageError
        $  "Extraneous "
        <> T.pack (show $ length posResidual)
        <> " positional argument(s)"
      | not (odNull kwResidual)
      = throwEdhSTM pgsCaller UsageError
        $  "Extraneous keyword arguments: "
        <> T.pack (unwords (show <$> odKeys kwResidual))
      | otherwise
      = exit'
    doReturn :: OrderedDict AttrKey EdhValue -> STM ()
    doReturn !es =
      -- insert a cycle tick here, so if no tx required for the call
      -- overall, the args receiving tx stops here then the callee
      -- runs in next stm transaction
      exitEdhSTM' pgsCaller (\_ -> exit es) (wuji pgsCaller)

  -- execution of the args receiving always in a tx for atomicity, and
  -- in the specified receiving (should be callee's outer) context
  local (const pgsRecv) $ case argsRcvr of
    PackReceiver argRcvrs -> contEdhSTM $ iopdEmpty >>= \ !em ->
      let
        go :: [ArgReceiver] -> ArgsPack -> STM ()
        go [] !apk' = woResidual apk' $ iopdSnapshot em >>= doReturn
        go (r : rest) !apk' =
          recvFromPack apk' em r $ \ !apk'' -> go rest apk''
      in
        go argRcvrs apk
    SingleReceiver argRcvr -> contEdhSTM $ iopdEmpty >>= \ !em ->
      recvFromPack apk em argRcvr
        $ \ !apk' -> woResidual apk' $ iopdSnapshot em >>= doReturn
    WildReceiver -> contEdhSTM $ if null posArgs
      then doReturn kwArgs
      else
        throwEdhSTM pgsRecv EvalError
        $  "Unexpected "
        <> T.pack (show $ length posArgs)
        <> " positional argument(s) to wild receiver"


-- | Pack args as expressions, normally in preparation of calling another
-- interpreter procedure
packEdhExprs :: ArgsPacker -> (ArgsPack -> EdhProc) -> EdhProc
packEdhExprs !pkrs !pkExit = ask >>= \ !pgs -> contEdhSTM $ do
  kwIOPD <- iopdEmpty
  let
    pkExprs :: [ArgSender] -> ([EdhValue] -> EdhProc) -> EdhProc
    pkExprs []       !exit = exit []
    pkExprs (x : xs) !exit = case x of
      UnpackPosArgs _ -> throwEdh EvalError "unpack to expr not supported yet"
      UnpackKwArgs _ -> throwEdh EvalError "unpack to expr not supported yet"
      UnpackPkArgs _ -> throwEdh EvalError "unpack to expr not supported yet"
      SendPosArg !argExpr -> pkExprs xs $ \ !posArgs -> contEdhSTM $ do
        !xu <- unsafeIOToSTM newUnique
        runEdhProc pgs $ exit (EdhExpr xu argExpr "" : posArgs)
      SendKwArg !kwAddr !argExpr ->
        contEdhSTM $ resolveEdhAttrAddr pgs kwAddr $ \ !kwKey -> do
          xu <- unsafeIOToSTM newUnique
          iopdInsert kwKey (EdhExpr xu argExpr "") kwIOPD
          runEdhProc pgs $ pkExprs xs $ \ !posArgs' -> exit posArgs'
  runEdhProc pgs $ pkExprs pkrs $ \ !args ->
    contEdhSTM $ iopdSnapshot kwIOPD >>= \ !kwargs ->
      runEdhProc pgs $ pkExit $ ArgsPack args kwargs


-- | Pack args as caller, normally in preparation of calling another procedure
packEdhArgs :: ArgsPacker -> (ArgsPack -> EdhProc) -> EdhProc
packEdhArgs !argSenders !pkExit = ask >>= \pgs -> contEdhSTM $ do
  let !pgsPacking = pgs
        {
          -- make sure values in a pack are evaluated in same tx
          edh'in'tx   = True
        , edh'context = (edh'context pgs) {
          -- discourage artifact definition during args packing
                                            contextPure = True }
        }
  !kwIOPD <- iopdEmpty
  let
    pkArgs :: [ArgSender] -> ([EdhValue] -> EdhProc) -> EdhProc
    pkArgs []       !exit = exit []
    pkArgs (x : xs) !exit = do
      let
        edhVal2Kw :: EdhValue -> STM () -> (AttrKey -> STM ()) -> STM ()
        edhVal2Kw !k !nopExit !exit' = case k of
          EdhString !name -> exit' $ AttrByName name
          EdhSymbol !sym  -> exit' $ AttrBySym sym
          _               -> nopExit
        dictKvs2Kwl
          :: [(ItemKey, EdhValue)]
          -> ([(AttrKey, EdhValue)] -> STM ())
          -> STM ()
        dictKvs2Kwl !ps !exit' = go ps []         where
          go :: [(ItemKey, EdhValue)] -> [(AttrKey, EdhValue)] -> STM ()
          go [] !kvl = exit' kvl
          go ((k, v) : rest) !kvl =
            edhVal2Kw k (go rest kvl) $ \ !k' -> go rest ((k', v) : kvl)
      case x of
        UnpackPosArgs !posExpr ->
          evalExpr posExpr $ \(OriginalValue !val _ _) ->
            case edhUltimate val of
              (EdhArgsPack (ArgsPack !posArgs _kwArgs)) ->
                pkArgs xs $ \ !posArgs' -> exit (posArgs ++ posArgs')
              (EdhPair !k !v) ->
                pkArgs xs $ \ !posArgs -> exit ([k, noneNil v] ++ posArgs)
              (EdhList (List _ !l)) -> pkArgs xs $ \ !posArgs ->
                contEdhSTM $ do
                  ll <- readTVar l
                  runEdhProc pgs $ exit ((noneNil <$> ll) ++ posArgs)
              _ ->
                throwEdh EvalError
                  $  "Can not unpack args from a "
                  <> T.pack (edhTypeNameOf val)
                  <> ": "
                  <> T.pack (show val)
        UnpackKwArgs !kwExpr -> evalExpr kwExpr $ \(OriginalValue !val _ _) ->
          case edhUltimate val of
            EdhArgsPack (ArgsPack _posArgs !kwArgs') -> contEdhSTM $ do
              iopdUpdate (odToList kwArgs') kwIOPD
              runEdhProc pgsPacking $ pkArgs xs $ \ !posArgs' -> exit posArgs'
            (EdhPair !k !v) ->
              contEdhSTM
                $ edhVal2Kw
                    k
                    (  throwEdhSTM pgs UsageError
                    $  "Invalid keyword type: "
                    <> T.pack (edhTypeNameOf k)
                    )
                $ \ !kw -> do
                    iopdInsert kw (noneNil $ edhDeCaseClose v) kwIOPD
                    runEdhProc pgsPacking $ pkArgs xs $ \ !posArgs ->
                      exit posArgs
            (EdhDict (Dict _ !ds)) -> contEdhSTM $ do
              !dkvl <- iopdToList ds
              dictKvs2Kwl dkvl $ \ !kvl -> do
                iopdUpdate kvl kwIOPD
                runEdhProc pgsPacking $ pkArgs xs $ \ !posArgs -> exit posArgs
            _ ->
              throwEdh EvalError
                $  "Can not unpack kwargs from a "
                <> T.pack (edhTypeNameOf val)
                <> ": "
                <> T.pack (show val)
        UnpackPkArgs !pkExpr -> evalExpr pkExpr $ \(OriginalValue !val _ _) ->
          case edhUltimate val of
            (EdhArgsPack (ArgsPack !posArgs !kwArgs')) -> contEdhSTM $ do
              iopdUpdate (odToList kwArgs') kwIOPD
              runEdhProc pgsPacking $ pkArgs xs $ \ !posArgs' ->
                exit (posArgs ++ posArgs')
            _ ->
              throwEdh EvalError
                $  "Can not unpack apk from a "
                <> T.pack (edhTypeNameOf val)
                <> ": "
                <> T.pack (show val)
        SendPosArg !argExpr -> evalExpr argExpr $ \(OriginalValue !val _ _) ->
          pkArgs xs
            $ \ !posArgs -> exit (noneNil (edhDeCaseClose val) : posArgs)
        SendKwArg !kwAddr !argExpr ->
          evalExpr argExpr $ \(OriginalValue !val _ _) -> case kwAddr of
            NamedAttr "_" ->  -- silently drop the value to keyword of single
              -- underscore, the user may just want its side-effect
              pkArgs xs $ \ !posArgs -> exit posArgs
            _ -> contEdhSTM $ resolveEdhAttrAddr pgs kwAddr $ \ !kwKey -> do
              iopdInsert kwKey (noneNil $ edhDeCaseClose val) kwIOPD
              runEdhProc pgs $ pkArgs xs $ \ !posArgs -> exit posArgs
  runEdhProc pgsPacking $ pkArgs argSenders $ \ !posArgs -> contEdhSTM $ do
    !kwArgs <- iopdSnapshot kwIOPD
    -- restore original tx state after args packed
    runEdhProc pgs $ pkExit $ ArgsPack posArgs kwArgs


val2DictEntry
  :: EdhProgState -> EdhValue -> ((ItemKey, EdhValue) -> STM ()) -> STM ()
val2DictEntry _ (EdhPair !k !v) !exit = exit (k, v)
val2DictEntry _ (EdhArgsPack (ArgsPack [!k, !v] !kwargs)) !exit
  | odNull kwargs = exit (k, v)
val2DictEntry !pgs !val _ = throwEdhSTM
  pgs
  UsageError
  ("Invalid entry for dict " <> T.pack (edhTypeNameOf val) <> ": " <> T.pack
    (show val)
  )

pvlToDict :: EdhProgState -> [EdhValue] -> (DictStore -> STM ()) -> STM ()
pvlToDict !pgs !pvl !exit = do
  !ds <- iopdEmpty
  let go []         = exit ds
      go (p : rest) = val2DictEntry pgs p $ \(!key, !val) -> do
        iopdInsert key val ds
        go rest
  go pvl

pvlToDictEntries
  :: EdhProgState -> [EdhValue] -> ([(ItemKey, EdhValue)] -> STM ()) -> STM ()
pvlToDictEntries !pgs !pvl !exit = do
  let go !entries [] = exit entries
      go !entries (p : rest) =
        val2DictEntry pgs p $ \ !entry -> go (entry : entries) rest
  go [] $ reverse pvl


edhValueNull :: EdhProgState -> EdhValue -> (Bool -> STM ()) -> STM ()
edhValueNull _    EdhNil                   !exit = exit True
edhValueNull !pgs (EdhNamedValue _ v     ) !exit = edhValueNull pgs v exit
edhValueNull _ (EdhDecimal d) !exit = exit $ D.decimalIsNaN d || d == 0
edhValueNull _    (EdhBool    b          ) !exit = exit $ not b
edhValueNull _    (EdhString  s          ) !exit = exit $ T.null s
edhValueNull _    (EdhSymbol  _          ) !exit = exit False
edhValueNull _    (EdhDict    (Dict _ ds)) !exit = iopdNull ds >>= exit
edhValueNull _    (EdhList    (List _ l )) !exit = null <$> readTVar l >>= exit
edhValueNull _ (EdhArgsPack (ArgsPack args kwargs)) !exit =
  exit $ null args && odNull kwargs
edhValueNull _ (EdhExpr _ (LitExpr NilLiteral) _) !exit = exit True
edhValueNull _ (EdhExpr _ (LitExpr (DecLiteral d)) _) !exit =
  exit $ D.decimalIsNaN d || d == 0
edhValueNull _ (EdhExpr _ (LitExpr (BoolLiteral b)) _) !exit = exit b
edhValueNull _ (EdhExpr _ (LitExpr (StringLiteral s)) _) !exit =
  exit $ T.null s
edhValueNull !pgs (EdhObject !o) !exit =
  lookupEdhObjAttr pgs o (AttrByName "__null__") >>= \case
    EdhNil -> exit False
    EdhMethod !nulMth ->
      runEdhProc pgs
        $ callEdhMethod o nulMth (ArgsPack [] odEmpty) id
        $ \(OriginalValue nulVal _ _) -> contEdhSTM $ case nulVal of
            EdhBool isNull -> exit isNull
            _              -> edhValueNull pgs nulVal exit
    EdhBool !b -> exit b
    badVal ->
      throwEdhSTM pgs UsageError
        $  "Invalid value type from __null__: "
        <> T.pack (edhTypeNameOf badVal)
edhValueNull _ _ !exit = exit False


edhIdentEqual :: EdhValue -> EdhValue -> Bool
edhIdentEqual (EdhNamedValue x'n x'v) (EdhNamedValue y'n y'v) =
  x'n == y'n && edhIdentEqual x'v y'v
edhIdentEqual EdhNamedValue{} _               = False
edhIdentEqual _               EdhNamedValue{} = False
edhIdentEqual x               y               = x == y

edhNamelyEqual
  :: EdhProgState -> EdhValue -> EdhValue -> (Bool -> STM ()) -> STM ()
edhNamelyEqual !pgs (EdhNamedValue !x'n !x'v) (EdhNamedValue !y'n !y'v) !exit =
  if x'n /= y'n then exit False else edhNamelyEqual pgs x'v y'v exit
edhNamelyEqual _ EdhNamedValue{} _               !exit = exit False
edhNamelyEqual _ _               EdhNamedValue{} !exit = exit False
edhNamelyEqual !pgs !x !y !exit =
  -- it's considered namely not equal if can not trivially concluded, i.e.
  -- may need to invoke magic methods or sth.
  edhValueEqual pgs x y $ exit . fromMaybe False

edhValueEqual
  :: EdhProgState -> EdhValue -> EdhValue -> (Maybe Bool -> STM ()) -> STM ()
edhValueEqual !pgs !lhVal !rhVal !exit =
  let
    lhv = edhUltimate lhVal
    rhv = edhUltimate rhVal
  in
    if lhv == rhv
      then -- identity equal
           exit $ Just True
      else case lhv of
        EdhList (List _ lhll) -> case rhv of
          EdhList (List _ rhll) -> do
            lhl <- readTVar lhll
            rhl <- readTVar rhll
            cmp2List lhl rhl $ exit . Just
          _ -> exit $ Just False
        EdhDict (Dict _ !lhd) -> case rhv of
          EdhDict (Dict _ !rhd) -> do
            lhl <- iopdToList lhd
            rhl <- iopdToList rhd
            -- regenerate the entry lists with HashMap to elide diffs in
            -- entry order
            cmp2Map (Map.toList $ Map.fromList lhl)
                    (Map.toList $ Map.fromList rhl)
              $ exit
              . Just
          _ -> exit $ Just False
        -- don't conclude it if either of the two is an object, so magic
        -- methods can get the chance to be invoked
        -- there may be some magic to be invoked and some may even return
        -- vectorized result
        EdhObject{} -> exit Nothing
        _           -> case rhv of
          EdhObject{} -> exit Nothing
          -- neither is object, not equal for sure
          _           -> exit $ Just False
 where
  cmp2List :: [EdhValue] -> [EdhValue] -> (Bool -> STM ()) -> STM ()
  cmp2List []      []      !exit' = exit' True
  cmp2List (_ : _) []      !exit' = exit' False
  cmp2List []      (_ : _) !exit' = exit' False
  cmp2List (lhVal' : lhRest) (rhVal' : rhRest) !exit' =
    edhValueEqual pgs lhVal' rhVal' $ \case
      Just True -> cmp2List lhRest rhRest exit'
      _         -> exit' False
  cmp2Map
    :: [(ItemKey, EdhValue)]
    -> [(ItemKey, EdhValue)]
    -> (Bool -> STM ())
    -> STM ()
  cmp2Map []      []      !exit' = exit' True
  cmp2Map (_ : _) []      !exit' = exit' False
  cmp2Map []      (_ : _) !exit' = exit' False
  cmp2Map ((lhKey, lhVal') : lhRest) ((rhKey, rhVal') : rhRest) !exit' =
    if lhKey /= rhKey
      then exit' False
      else edhValueEqual pgs lhVal' rhVal' $ \case
        Just True -> cmp2Map lhRest rhRest exit'
        _         -> exit' False


-- comma separated repr string
_edhCSR :: [Text] -> [EdhValue] -> EdhProcExit -> EdhProc
_edhCSR reprs [] !exit =
  exitEdhProc exit $ EdhString $ T.concat [ i <> ", " | i <- reverse reprs ]
_edhCSR reprs (v : rest) !exit = edhValueRepr v $ \(OriginalValue r _ _) ->
  case r of
    EdhString repr -> _edhCSR (repr : reprs) rest exit
    _              -> error "bug: edhValueRepr returned non-string in CPS"
-- comma separated repr string for kwargs
_edhKwArgsCSR
  :: [(Text, Text)] -> [(AttrKey, EdhValue)] -> EdhProcExit -> EdhProc
_edhKwArgsCSR !entries [] !exit' = exitEdhProc exit' $ EdhString $ T.concat
  [ k <> "=" <> v <> ", " | (k, v) <- entries ]
_edhKwArgsCSR !entries ((k, v) : rest) exit' =
  edhValueRepr v $ \(OriginalValue r _ _) -> case r of
    EdhString repr ->
      _edhKwArgsCSR ((T.pack (show k), repr) : entries) rest exit'
    _ -> error "bug: edhValueRepr returned non-string in CPS"
-- comma separated repr string for dict entries
_edhDictCSR
  :: [(Text, Text)] -> [(EdhValue, EdhValue)] -> EdhProcExit -> EdhProc
_edhDictCSR entries [] !exit' = exitEdhProc exit' $ EdhString $ T.concat
  [ k <> ":" <> v <> ", " | (k, v) <- entries ]
_edhDictCSR entries ((k, v) : rest) exit' =
  edhValueRepr k $ \(OriginalValue kr _ _) -> case kr of
    EdhString !kRepr -> do
      let krDecor :: Text -> Text
          krDecor = case k of
            -- quote the key repr in the entry if it's a term
            -- bcoz (:=) precedence is 1, less than (:)'s 2
            EdhNamedValue{} -> \r -> "(" <> r <> ")"
            _               -> id
          vrDecor :: Text -> Text
          vrDecor = case v of
            -- quote the value repr in the entry if it's a pair
            EdhPair{} -> \r -> "(" <> r <> ")"
            _         -> id
      edhValueRepr v $ \(OriginalValue vr _ _) -> case vr of
        EdhString !vRepr ->
          _edhDictCSR ((krDecor kRepr, vrDecor vRepr) : entries) rest exit'
        _ -> error "bug: edhValueRepr returned non-string in CPS"
    _ -> error "bug: edhValueRepr returned non-string in CPS"

edhValueReprSTM :: EdhProgState -> EdhValue -> (Text -> STM ()) -> STM ()
edhValueReprSTM !pgs !val !exit =
  runEdhProc pgs $ edhValueRepr val $ \(OriginalValue vr _ _) -> case vr of
    EdhString !r -> contEdhSTM $ exit r
    _            -> error "bug: edhValueRepr returned non-string"

edhValueRepr :: EdhValue -> EdhProcExit -> EdhProc

-- pair repr
edhValueRepr (EdhPair v1 v2) !exit =
  edhValueRepr v1 $ \(OriginalValue r1 _ _) -> case r1 of
    EdhString repr1 -> edhValueRepr v2 $ \(OriginalValue r2 _ _) -> case r2 of
      EdhString repr2 -> exitEdhProc exit $ EdhString $ repr1 <> ":" <> repr2
      _               -> error "bug: edhValueRepr returned non-string in CPS"
    _ -> error "bug: edhValueRepr returned non-string in CPS"

-- apk repr
edhValueRepr (EdhArgsPack (ArgsPack !args !kwargs)) !exit
  | null args && odNull kwargs = exitEdhProc exit $ EdhString "()"
  | otherwise = _edhCSR [] args $ \(OriginalValue argsR _ _) -> case argsR of
    EdhString argsCSR ->
      _edhKwArgsCSR [] (odToReverseList kwargs)
        $ \(OriginalValue kwargsR _ _) -> case kwargsR of
            EdhString kwargsCSR ->
              exitEdhProc exit $ EdhString $ "( " <> argsCSR <> kwargsCSR <> ")"
            _ -> error "bug: edhValueRepr returned non-string in CPS"
    _ -> error "bug: edhValueRepr returned non-string in CPS"

-- list repr
edhValueRepr (EdhList (List _ ls)) !exit = do
  pgs <- ask
  contEdhSTM $ readTVar ls >>= \vs -> if null vs
    then -- no space should show in an empty list
         exitEdhSTM pgs exit $ EdhString "[]"
    else runEdhProc pgs $ _edhCSR [] vs $ \(OriginalValue csr _ _) ->
      case csr of
        -- advocate trailing comma here
        EdhString !csRepr ->
          exitEdhProc exit $ EdhString $ "[ " <> csRepr <> "]"
        _ -> error "bug: edhValueRepr returned non-string in CPS"

-- dict repr
edhValueRepr (EdhDict (Dict _ !ds)) !exit = do
  pgs <- ask
  contEdhSTM $ iopdNull ds >>= \case
    True -> -- no space should show in an empty dict
      exitEdhSTM pgs exit $ EdhString "{}"
    False -> iopdToReverseList ds >>= \ !entries ->
      runEdhProc pgs
        $ _edhDictCSR [] entries
        $ \(OriginalValue entriesR _ _) -> case entriesR of
            EdhString entriesCSR ->
              exitEdhProc exit $ EdhString $ "{ " <> entriesCSR <> "}"
            _ -> error "bug: edhValueRepr returned non-string in CPS"

-- object repr
edhValueRepr (EdhObject !o) !exit = do
  pgs <- ask
  contEdhSTM $ lookupEdhObjAttr pgs o (AttrByName "__repr__") >>= \case
    EdhNil           -> exitEdhSTM pgs exit $ EdhString $ T.pack $ show o
    repr@EdhString{} -> exitEdhSTM pgs exit repr
    EdhMethod !reprMth ->
      runEdhProc pgs
        $ callEdhMethod o reprMth (ArgsPack [] odEmpty) id
        $ \(OriginalValue reprVal _ _) -> case reprVal of
            s@EdhString{} -> exitEdhProc exit s
            _             -> edhValueRepr reprVal exit
    reprVal -> runEdhProc pgs $ edhValueRepr reprVal exit

-- repr of named value
edhValueRepr (EdhNamedValue !n v@EdhNamedValue{}) !exit =
  -- Edh operators are all left-associative, parenthesis needed
  edhValueRepr v $ \(OriginalValue r _ _) -> case r of
    EdhString repr ->
      exitEdhProc exit $ EdhString $ n <> " := (" <> repr <> ")"
    _ -> error "bug: edhValueRepr returned non-string in CPS"
edhValueRepr (EdhNamedValue !n !v) !exit =
  edhValueRepr v $ \(OriginalValue r _ _) -> case r of
    EdhString repr -> exitEdhProc exit $ EdhString $ n <> " := " <> repr
    _              -> error "bug: edhValueRepr returned non-string in CPS"

-- repr of other values simply as to show itself
edhValueRepr !v !exit = exitEdhProc exit $ EdhString $ T.pack $ show v


edhValueStr :: EdhValue -> EdhProcExit -> EdhProc
edhValueStr s@EdhString{} !exit' = exitEdhProc exit' s
edhValueStr !v            !exit' = edhValueRepr v exit'


withThatEntity
  :: forall a . Typeable a => (EdhProgState -> a -> STM ()) -> EdhProc
withThatEntity = withThatEntity'
  $ \ !pgs -> throwEdhSTM pgs UsageError "bug: unexpected entity storage type"
withThatEntity'
  :: forall a
   . Typeable a
  => (EdhProgState -> STM ())
  -> (EdhProgState -> a -> STM ())
  -> EdhProc
withThatEntity' !naExit !exit = ask >>= \ !pgs ->
  contEdhSTM
    $   fromDynamic
    <$> readTVar
          (entity'store $ objEntity $ thatObject $ contextScope $ edh'context
            pgs
          )
    >>= \case
          Nothing   -> naExit pgs

          Just !esd -> exit pgs esd

withEntityOfClass
  :: forall a
   . Typeable a
  => Unique
  -> (EdhProgState -> a -> STM ())
  -> EdhProc
withEntityOfClass !classUniq = withEntityOfClass' classUniq
  $ \ !pgs -> throwEdhSTM pgs UsageError "bug: unexpected entity storage type"
withEntityOfClass'
  :: forall a
   . Typeable a
  => Unique
  -> (EdhProgState -> STM ())
  -> (EdhProgState -> a -> STM ())
  -> EdhProc
withEntityOfClass' !classUniq !naExit !exit = ask >>= \ !pgs -> contEdhSTM $ do
  let !that = thatObject $ contextScope $ edh'context pgs
  resolveEdhInstance pgs classUniq that >>= \case
    Nothing -> naExit pgs
    Just !inst ->
      fromDynamic <$> readTVar (entity'store $ objEntity inst) >>= \case
        Nothing   -> naExit pgs

        Just !esd -> exit pgs esd


modifyThatEntity
  :: forall a
   . Typeable a
  => EdhProcExit
  -> (EdhProgState -> a -> (a -> EdhValue -> STM ()) -> STM ())
  -> EdhProc
modifyThatEntity !exit !esMod = modifyThatEntity'
  (\ !pgs ->
    throwEdhSTM pgs UsageError "bug: unexpected heavy entity storage type"
  )
  exit
  esMod
modifyThatEntity'
  :: forall a
   . Typeable a
  => (EdhProgState -> STM ())
  -> EdhProcExit
  -> (EdhProgState -> a -> (a -> EdhValue -> STM ()) -> STM ())
  -> EdhProc
modifyThatEntity' !naExit !exit !esMod = ask >>= \ !pgs -> contEdhSTM $ do
  let !esv =
        entity'store $ objEntity $ thatObject $ contextScope $ edh'context pgs
  fromDynamic <$> readTVar esv >>= \case
    Nothing                -> naExit pgs
    Just (esmv :: TMVar a) -> do
      !esd <- takeTMVar esmv
      let tryAct !pgs' !exit' = esMod pgs' esd $ \ !esd' !exitVal -> do
            putTMVar esmv esd'
            exitEdhSTM pgs' exit' exitVal
      edhCatchSTM pgs tryAct exit $ \_pgsThrower _exv _recover rethrow -> do
        void $ tryPutTMVar esmv esd
        rethrow

modifyEntityOfClass
  :: forall a
   . Typeable a
  => Unique
  -> EdhProcExit
  -> (EdhProgState -> a -> (a -> EdhValue -> STM ()) -> STM ())
  -> EdhProc
modifyEntityOfClass !classUniq !exit !esMod = modifyEntityOfClass'
  classUniq
  (\ !pgs ->
    throwEdhSTM pgs UsageError "bug: unexpected heavy entity storage type"
  )
  exit
  esMod
modifyEntityOfClass'
  :: forall a
   . Typeable a
  => Unique
  -> (EdhProgState -> STM ())
  -> EdhProcExit
  -> (EdhProgState -> a -> (a -> EdhValue -> STM ()) -> STM ())
  -> EdhProc
modifyEntityOfClass' !classUniq !naExit !exit !esMod = ask >>= \ !pgs ->
  contEdhSTM $ do
    let !that = thatObject $ contextScope $ edh'context pgs
    resolveEdhInstance pgs classUniq that >>= \case
      Nothing    -> naExit pgs
      Just !inst -> do
        let !esv = entity'store $ objEntity inst
        fromDynamic <$> readTVar esv >>= \case
          Nothing                -> naExit pgs
          Just (esmv :: TMVar a) -> do
            !esd <- takeTMVar esmv
            let tryAct !pgs' !exit' = esMod pgs' esd $ \ !esd' !exitVal -> do
                  putTMVar esmv esd'
                  exitEdhSTM pgs' exit' exitVal
            edhCatchSTM pgs tryAct exit $ \_pgsThrower _exv _recover rethrow ->
              do
                void $ tryPutTMVar esmv esd
                rethrow


resolveEdhCallee
  :: EdhProgState
  -> Expr
  -> ((OriginalValue, Scope -> Scope) -> STM ())
  -> STM ()
resolveEdhCallee !pgs !expr !exit = case expr of
  PerformExpr !effAddr -> resolveEdhAttrAddr pgs effAddr $ \ !effKey ->
    resolveEdhEffCallee pgs effKey edhTargetStackForPerform exit
  BehaveExpr !effAddr -> resolveEdhAttrAddr pgs effAddr
    $ \ !effKey -> resolveEdhEffCallee pgs effKey edhTargetStackForBehave exit
  _ -> runEdhProc pgs $ evalExpr expr $ \ov@(OriginalValue !v _ _) ->
    contEdhSTM $ exit (ov { valueFromOrigin = edhDeCaseClose v }, id)

resolveEdhEffCallee
  :: EdhProgState
  -> AttrKey
  -> (EdhProgState -> [Scope])
  -> ((OriginalValue, Scope -> Scope) -> STM ())
  -> STM ()
resolveEdhEffCallee !pgs !effKey !targetStack !exit =
  resolveEffectfulAttr pgs (targetStack pgs) (attrKeyValue effKey) >>= \case
    Just (!effArt, !outerStack) -> exit
      ( OriginalValue effArt scope $ thisObject scope
      , \ !procScope -> procScope { effectsStack = outerStack }
      )
    Nothing ->
      throwEdhSTM pgs UsageError $ "No such effect: " <> T.pack (show effKey)
  where !scope = contextScope $ edh'context pgs

edhTargetStackForPerform :: EdhProgState -> [Scope]
edhTargetStackForPerform !pgs = case effectsStack scope of
  []         -> NE.tail $ callStack ctx
  outerStack -> outerStack
 where
  !ctx   = edh'context pgs
  !scope = contextScope ctx

edhTargetStackForBehave :: EdhProgState -> [Scope]
edhTargetStackForBehave !pgs = NE.tail $ callStack ctx
  where !ctx = edh'context pgs

resolveEdhPerform :: EdhProgState -> AttrKey -> (EdhValue -> STM ()) -> STM ()
resolveEdhPerform !pgs !effKey !exit =
  resolveEffectfulAttr pgs (edhTargetStackForPerform pgs) (attrKeyValue effKey)
    >>= \case
          Just (!effArt, _) -> exit effArt
          Nothing -> throwEdhSTM pgs UsageError $ "No such effect: " <> T.pack
            (show effKey)

resolveEdhBehave :: EdhProgState -> AttrKey -> (EdhValue -> STM ()) -> STM ()
resolveEdhBehave !pgs !effKey !exit =
  resolveEffectfulAttr pgs (edhTargetStackForBehave pgs) (attrKeyValue effKey)
    >>= \case
          Just (!effArt, _) -> exit effArt
          Nothing -> throwEdhSTM pgs UsageError $ "No such effect: " <> T.pack
            (show effKey)


parseEdhIndex
  :: EdhProgState -> EdhValue -> (Either Text EdhIndex -> STM ()) -> STM ()
parseEdhIndex !pgs !val !exit = case val of

  -- empty  
  EdhArgsPack (ArgsPack [] !kwargs') | odNull kwargs' -> exit $ Right EdhAll

  -- term
  EdhNamedValue "All" _ -> exit $ Right EdhAll
  EdhNamedValue "Any" _ -> exit $ Right EdhAny
  EdhNamedValue _ !termVal -> parseEdhIndex pgs termVal exit

  -- range 
  EdhPair (EdhPair !startVal !stopVal) !stepVal -> sliceNum startVal $ \case
    Left  !err   -> exit $ Left err
    Right !start -> sliceNum stopVal $ \case
      Left  !err  -> exit $ Left err
      Right !stop -> sliceNum stepVal $ \case
        Left  !err -> exit $ Left err
        Right step -> exit $ Right $ EdhSlice start stop step
  EdhPair !startVal !stopVal -> sliceNum startVal $ \case
    Left  !err   -> exit $ Left err
    Right !start -> sliceNum stopVal $ \case
      Left  !err  -> exit $ Left err
      Right !stop -> exit $ Right $ EdhSlice start stop Nothing

  -- single
  _ -> sliceNum val $ \case
    Right Nothing   -> exit $ Right EdhAll
    Right (Just !i) -> exit $ Right $ EdhIndex i
    Left  !err      -> exit $ Left err

 where
  sliceNum :: EdhValue -> (Either Text (Maybe Int) -> STM ()) -> STM ()
  sliceNum !val' !exit' = case val' of

    -- number
    EdhDecimal !idxNum -> case D.decimalToInteger idxNum of
      Just !i -> exit' $ Right $ Just $ fromInteger i
      _ ->
        exit'
          $  Left
          $  "An integer expected as index number but given: "
          <> T.pack (show idxNum)

    -- term
    EdhNamedValue "All" _        -> exit' $ Right Nothing
    EdhNamedValue "Any" _        -> exit' $ Right Nothing
    EdhNamedValue _     !termVal -> sliceNum termVal exit'

    !badIdxNum -> edhValueReprSTM pgs badIdxNum $ \ !badIdxNumRepr ->
      exit'
        $  Left
        $  "Bad index number of "
        <> T.pack (edhTypeNameOf badIdxNum)
        <> ": "
        <> badIdxNumRepr


edhRegulateSlice
  :: EdhProgState
  -> Int
  -> (Maybe Int, Maybe Int, Maybe Int)
  -> ((Int, Int, Int) -> STM ())
  -> STM ()
edhRegulateSlice !pgs !len (!start, !stop, !step) !exit = case step of
  Nothing -> case start of
    Nothing -> case stop of
      Nothing     -> exit (0, len, 1)

      -- (Any:iStop:Any)
      Just !iStop -> if iStop < 0
        then
          let iStop' = len + iStop
          in  if iStop' < 0
                then
                  throwEdhSTM pgs UsageError
                  $  "Stop index out of bounds: "
                  <> T.pack (show iStop)
                  <> " vs "
                  <> T.pack (show len)
                else exit (0, iStop', 1)
        else if iStop > len
          then
            throwEdhSTM pgs EvalError
            $  "Stop index out of bounds: "
            <> T.pack (show iStop)
            <> " vs "
            <> T.pack (show len)
          else exit (0, iStop, 1)

    Just !iStart -> case stop of

      -- (iStart:Any:Any)
      Nothing -> if iStart < 0
        then
          let iStart' = len + iStart
          in  if iStart' < 0
                then
                  throwEdhSTM pgs UsageError
                  $  "Start index out of bounds: "
                  <> T.pack (show iStart)
                  <> " vs "
                  <> T.pack (show len)
                else exit (iStart', len, 1)
        else if iStart > len
          then
            throwEdhSTM pgs UsageError
            $  "Start index out of bounds: "
            <> T.pack (show iStart)
            <> " vs "
            <> T.pack (show len)
          else exit (iStart, len, 1)

      -- (iStart:iStop:Any)
      Just !iStop -> do
        let !iStart' = if iStart < 0 then len + iStart else iStart
            !iStop'  = if iStop < 0 then len + iStop else iStop
        if iStart' < 0
          then
            throwEdhSTM pgs UsageError
            $  "Start index out of bounds: "
            <> T.pack (show iStart)
            <> " vs "
            <> T.pack (show len)
          else if iStop' < 0
            then
              throwEdhSTM pgs EvalError
              $  "Stop index out of bounds: "
              <> T.pack (show iStop)
              <> " vs "
              <> T.pack (show len)
            else if iStart' <= iStop'
              then
                (if iStop' > len
                  then
                    throwEdhSTM pgs EvalError
                    $  "Stop index out of bounds: "
                    <> T.pack (show iStop)
                    <> " vs "
                    <> T.pack (show len)
                  else if iStart' >= len
                    then
                      throwEdhSTM pgs UsageError
                      $  "Start index out of bounds: "
                      <> T.pack (show iStart)
                      <> " vs "
                      <> T.pack (show len)
                    else exit (iStart', iStop', 1)
                )
              else
                (if iStop' >= len
                  then
                    throwEdhSTM pgs EvalError
                    $  "Stop index out of bounds: "
                    <> T.pack (show iStop)
                    <> " vs "
                    <> T.pack (show len)
                  else if iStart' > len
                    then
                      throwEdhSTM pgs UsageError
                      $  "Start index out of bounds: "
                      <> T.pack (show iStart)
                      <> " vs "
                      <> T.pack (show len)
                    else exit (iStart', iStop', -1)
                )

  Just !iStep -> if iStep == 0
    then throwEdhSTM pgs UsageError "Step can not be zero in slice"
    else if iStep < 0
      then
        (case start of
          Nothing -> case stop of

            -- (Any:Any: -n)
            Nothing     -> exit (len - 1, -1, iStep)

            -- (Any:iStop: -n)
            Just !iStop -> if iStop == -1
              then exit (len - 1, -1, iStep)
              else do
                let !iStop' = if iStop < 0 then len + iStop else iStop
                if iStop' < -1 || iStop' >= len - 1
                  then
                    throwEdhSTM pgs EvalError
                    $  "Backward stop index out of bounds: "
                    <> T.pack (show iStop)
                    <> " vs "
                    <> T.pack (show len)
                  else exit (len - 1, iStop', iStep)

          Just !iStart -> case stop of

            -- (iStart:Any: -n)
            Nothing -> do
              let !iStart' = if iStart < 0 then len + iStart else iStart
              if iStart' < 0 || iStart' >= len
                then
                  throwEdhSTM pgs UsageError
                  $  "Backward start index out of bounds: "
                  <> T.pack (show iStart)
                  <> " vs "
                  <> T.pack (show len)
                else exit (iStart', -1, iStep)

            -- (iStart:iStop: -n)
            Just !iStop -> do
              let !iStart' = if iStart < 0 then len + iStart else iStart
              if iStart' < 0 || iStart' >= len
                then
                  throwEdhSTM pgs UsageError
                  $  "Backward start index out of bounds: "
                  <> T.pack (show iStart)
                  <> " vs "
                  <> T.pack (show len)
                else if iStop == -1
                  then exit (iStart', -1, iStep)
                  else do
                    let !iStop' = if iStop < 0 then len + iStop else iStop
                    if iStop' < -1 || iStop >= len - 1
                      then
                        throwEdhSTM pgs EvalError
                        $  "Backward stop index out of bounds: "
                        <> T.pack (show iStop)
                        <> " vs "
                        <> T.pack (show len)
                      else if iStart' < iStop'
                        then
                          throwEdhSTM pgs EvalError
                          $  "Can not step backward from "
                          <> T.pack (show iStart)
                          <> " to "
                          <> T.pack (show iStop)
                        else exit (iStart', iStop', iStep)
        )
      else -- iStep > 0
        (case start of
          Nothing -> case stop of

            -- (Any:Any:n)
            Nothing     -> exit (0, len, iStep)

            -- (Any:iStop:n)
            Just !iStop -> do
              let !iStop' = if iStop < 0 then len + iStop else iStop
              if iStop' < 0 || iStop' > len
                then
                  throwEdhSTM pgs EvalError
                  $  "Stop index out of bounds: "
                  <> T.pack (show iStop)
                  <> " vs "
                  <> T.pack (show len)
                else exit (0, iStop', iStep)

          Just !iStart -> case stop of

            -- (iStart:Any:n)
            Nothing -> do
              let !iStart' = if iStart < 0 then len + iStart else iStart
              if iStart' < 0 || iStart' >= len
                then
                  throwEdhSTM pgs UsageError
                  $  "Start index out of bounds: "
                  <> T.pack (show iStart)
                  <> " vs "
                  <> T.pack (show len)
                else exit (iStart', len, iStep)

            -- (iStart:iStop:n)
            Just !iStop -> do
              let !iStart' = if iStart < 0 then len + iStart else iStart
              let !iStop'  = if iStop < 0 then len + iStop else iStop
              if iStart' > iStop'
                then
                  throwEdhSTM pgs EvalError
                  $  "Can not step from "
                  <> T.pack (show iStart)
                  <> " to "
                  <> T.pack (show iStop)
                else exit (iStart', iStop', iStep)
        )


edhRegulateIndex :: EdhProgState -> Int -> Int -> (Int -> STM ()) -> STM ()
edhRegulateIndex !pgs !len !idx !exit =
  let !posIdx = if idx < 0  -- Python style negative index
        then idx + len
        else idx
  in  if posIdx < 0 || posIdx >= len
        then
          throwEdhSTM pgs EvalError
          $  "Index out of bounds: "
          <> T.pack (show idx)
          <> " vs "
          <> T.pack (show len)
        else exit posIdx

