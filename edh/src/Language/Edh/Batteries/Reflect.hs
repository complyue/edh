
module Language.Edh.Batteries.Reflect where

import           Prelude
-- import           Debug.Trace

import           Control.Monad.Reader
import           Control.Concurrent.STM

import           Data.List.NonEmpty             ( (<|) )
import qualified Data.List.NonEmpty            as NE
import qualified Data.Text                     as T
import qualified Data.HashMap.Strict           as Map

import           Text.Megaparsec

import           Data.Lossless.Decimal          ( decimalToInteger )

import           Language.Edh.Control
import           Language.Edh.Details.RtTypes
import           Language.Edh.Details.Evaluate


-- | utility constructor(*args,**kwargs)
ctorProc :: EdhProcedure
ctorProc (ArgsPack !args !kwargs) !exit = do
  !pgs <- ask
  let callerCtx   = edh'context pgs
      callerScope = contextScope callerCtx
      !argsCls    = edhClassOf <$> args
  if null kwargs
    then case argsCls of
      []  -> exitEdhProc exit (EdhClass $ objClass $ thisObject callerScope)
      [t] -> exitEdhProc exit t
      _   -> exitEdhProc exit (EdhTuple argsCls)
    else exitEdhProc
      exit
      (EdhArgsPack $ ArgsPack argsCls $ Map.map edhClassOf kwargs)
 where
  edhClassOf :: EdhValue -> EdhValue
  edhClassOf (EdhObject o) = EdhClass $ objClass o
  edhClassOf _             = nil

-- | utility supers(*args,**kwargs)
supersProc :: EdhProcedure
supersProc (ArgsPack !args !kwargs) !exit = do
  !pgs <- ask
  let !callerCtx   = edh'context pgs
      !callerScope = contextScope callerCtx
  if null args && Map.null kwargs
    then contEdhSTM $ do
      supers <-
        map EdhObject <$> (readTVar $ objSupers $ thatObject callerScope)
      exitEdhSTM pgs exit (EdhTuple supers)
    else if null kwargs
      then case args of
        [v] -> contEdhSTM $ do
          supers <- supersOf v
          exitEdhSTM pgs exit supers
        _ -> contEdhSTM $ do
          argsSupers <- sequence $ supersOf <$> args
          exitEdhSTM pgs exit (EdhTuple argsSupers)
      else contEdhSTM $ do
        argsSupers   <- sequence $ supersOf <$> args
        kwargsSupers <- sequence $ Map.map supersOf kwargs
        exitEdhSTM pgs exit (EdhArgsPack $ ArgsPack argsSupers kwargsSupers)
 where
  supersOf :: EdhValue -> STM EdhValue
  supersOf v = case v of
    EdhObject o ->
      map EdhObject <$> readTVar (objSupers o) >>= return . EdhTuple
    _ -> return nil


-- | utility scope()
-- obtain current scope as reflected object
scopeObtainProc :: EdhProcedure
scopeObtainProc (ArgsPack _args !kwargs) !exit = do
  !pgs <- ask
  let !ctx = edh'context pgs
  case Map.lookup "ofObj" kwargs of
    Just (EdhObject ofObj) -> contEdhSTM $ do
      wrapperObj <- mkScopeWrapper ctx $ objectScope ctx ofObj
      exitEdhSTM pgs exit $ EdhObject wrapperObj
    _ -> do
      let unwind :: Int
          !unwind = case Map.lookup "unwind" kwargs of
            Just (EdhDecimal d) -> case decimalToInteger d of
              Just n  -> fromIntegral n
              Nothing -> 0
            _ -> 0
          scopeFromStack :: Int -> [Scope] -> (Scope -> STM ()) -> STM ()
          scopeFromStack _ [] _ = throwEdhSTM pgs UsageError "stack underflow"
          scopeFromStack c (f : _) !exit' | c <= 0 = exit' f
          scopeFromStack c (_ : s) !exit' = scopeFromStack (c - 1) s exit'
      contEdhSTM
        $ scopeFromStack unwind (NE.tail (callStack ctx))
        $ \tgtScope -> do
            wrapperObj <- mkScopeWrapper ctx tgtScope
            exitEdhSTM pgs exit $ EdhObject wrapperObj


-- | utility scope.attrs()
-- get attribute types in the scope
scopeAttrsProc :: EdhProcedure
scopeAttrsProc _ !exit = do
  !pgs <- ask
  let !that = thatObject $ contextScope $ edh'context pgs
  contEdhSTM $ do
    ad <- edhDictFromEntity pgs $ scopeEntity $ wrappedScopeOf that
    exitEdhSTM pgs exit $ EdhDict ad


-- | repr of a scope
scopeReprProc :: EdhProcedure
scopeReprProc _ !exit = do
  !pgs <- ask
  let !that                = thatObject $ contextScope $ edh'context pgs
      ProcDecl _ _ !spBody = procedure'decl $ objClass that
  exitEdhProc exit $ EdhString $ case spBody of
    Left (StmtSrc (srcLoc, _)) ->
      "#scope# " <> (T.pack $ sourcePosPretty srcLoc)
    Right _ -> "#host scope#"


-- | utility scope.lexiLoc()
-- get lexical source locations formated as a string, from the wrapped scope
scopeCallerLocProc :: EdhProcedure
scopeCallerLocProc _ !exit = do
  !pgs <- ask
  let !that = thatObject $ contextScope $ edh'context pgs
  case procedure'lexi $ objClass that of
    Nothing -> -- inner and outer of this scope are the two poles
      -- generated from *Taiji*, i.e. from oneness to duality
      exitEdhProc exit $ EdhString "<SupremeUltimate>"
    Just !callerLexi -> do
      let StmtSrc (!srcLoc, _) = scopeCaller callerLexi
      exitEdhProc exit $ EdhString $ T.pack $ sourcePosPretty srcLoc


-- | utility scope.lexiLoc()
-- get lexical source locations formated as a string, from the wrapped scope
scopeLexiLocProc :: EdhProcedure
scopeLexiLocProc _ !exit = do
  !pgs <- ask
  let !that                = thatObject $ contextScope $ edh'context pgs
      ProcDecl _ _ !spBody = procedure'decl $ objClass that
  exitEdhProc exit $ EdhString $ case spBody of
    Left  (StmtSrc (srcLoc, _)) -> T.pack $ sourcePosPretty srcLoc
    Right _                     -> "<host-code>"


-- | utility scope.outer()
-- get lexical outer scope of the wrapped scope
scopeOuterProc :: EdhProcedure
scopeOuterProc _ !exit = do
  !pgs <- ask
  let !ctx  = edh'context pgs
      !that = thatObject $ contextScope ctx
  case outerScopeOf $ wrappedScopeOf that of
    Nothing     -> exitEdhProc exit nil
    Just !outer -> contEdhSTM $ do
      wrapperObj <- mkScopeWrapper ctx outer
      exitEdhSTM pgs exit $ EdhObject wrapperObj


-- | utility scope.get(k1, k2, n1=k3, n2=k4, ...)
-- get attribute values from the wrapped scope
scopeGetProc :: EdhProcedure
scopeGetProc (ArgsPack !args !kwargs) !exit = do
  !pgs <- ask
  let !callerCtx = edh'context pgs
      !that      = thatObject $ contextScope callerCtx
      !ent       = scopeEntity $ wrappedScopeOf that
      lookupAttrs
        :: [EdhValue]
        -> [(AttrName, EdhValue)]
        -> [EdhValue]
        -> [(AttrName, EdhValue)]
        -> (([EdhValue], [(AttrName, EdhValue)]) -> STM ())
        -> STM ()
      lookupAttrs rtnArgs rtnKwArgs [] [] !exit' = exit' (rtnArgs, rtnKwArgs)
      lookupAttrs rtnArgs rtnKwArgs [] ((n, v) : restKwArgs) !exit' =
        attrKeyFrom pgs v $ \k -> do
          attrVal <- lookupEntityAttr pgs ent k
          lookupAttrs rtnArgs ((n, attrVal) : rtnKwArgs) [] restKwArgs exit'
      lookupAttrs rtnArgs rtnKwArgs (v : restArgs) kwargs' !exit' =
        attrKeyFrom pgs v $ \k -> do
          attrVal <- lookupEntityAttr pgs ent k
          lookupAttrs (attrVal : rtnArgs) rtnKwArgs restArgs kwargs' exit'
  contEdhSTM $ lookupAttrs [] [] args (Map.toList kwargs) $ \case
    ([v]    , []       ) -> exitEdhSTM pgs exit v
    (rtnArgs, rtnKwArgs) -> exitEdhSTM pgs exit $ EdhArgsPack $ ArgsPack
      (reverse rtnArgs)
      (Map.fromList rtnKwArgs)
 where
  attrKeyFrom :: EdhProgState -> EdhValue -> (AttrKey -> STM ()) -> STM ()
  attrKeyFrom _   (EdhString attrName) !exit' = exit' $ AttrByName attrName
  attrKeyFrom _   (EdhSymbol sym     ) !exit' = exit' $ AttrBySym sym
  attrKeyFrom pgs badVal               _      = throwEdhSTM
    pgs
    UsageError
    ("Invalid attribute reference type - " <> T.pack (show $ edhTypeOf badVal))


-- | utility scope.put(k1:v1, k2:v2, n3=v3, n4=v4, ...)
-- put attribute values into the wrapped scope
scopePutProc :: EdhProcedure
scopePutProc (ArgsPack !args !kwargs) !exit = do
  !pgs <- ask
  let !callerCtx = edh'context pgs
      !that      = thatObject $ contextScope callerCtx
      !ent       = scopeEntity $ wrappedScopeOf that
  contEdhSTM $ putAttrs pgs args [] $ \attrs -> do
    updateEntityAttrs pgs ent
      $  attrs
      ++ [ (AttrByName k, v) | (k, v) <- Map.toList kwargs ]
    exitEdhSTM pgs exit nil
 where
  putAttrs
    :: EdhProgState
    -> [EdhValue]
    -> [(AttrKey, EdhValue)]
    -> ([(AttrKey, EdhValue)] -> STM ())
    -> STM ()
  putAttrs _   []           cumu !exit' = exit' cumu
  putAttrs pgs (arg : rest) cumu !exit' = case arg of
    EdhPair (EdhString !k) !v ->
      putAttrs pgs rest ((AttrByName k, v) : cumu) exit'
    EdhPair (EdhSymbol !k) !v ->
      putAttrs pgs rest ((AttrBySym k, v) : cumu) exit'
    EdhTuple [EdhString !k, v] ->
      putAttrs pgs rest ((AttrByName k, v) : cumu) exit'
    EdhTuple [EdhSymbol !k, v] ->
      putAttrs pgs rest ((AttrBySym k, v) : cumu) exit'
    _ ->
      throwEdhSTM pgs UsageError
        $  "Invalid key/value type to put into a scope - "
        <> T.pack (edhTypeNameOf arg)


-- | utility scope.eval(expr1, expr2, kw3=expr3, kw4=expr4, ...)
-- evaluate expressions in this scope
scopeEvalProc :: EdhProcedure
scopeEvalProc (ArgsPack !args !kwargs) !exit = do
  !pgs <- ask
  let
    !callerCtx      = edh'context pgs
    !that           = thatObject $ contextScope callerCtx
    !theScope       = wrappedScopeOf that
    -- eval all exprs with the original scope as the only scope in call stack
    !scopeCallStack = theScope <| callStack callerCtx
    evalThePack
      :: [EdhValue]
      -> Map.HashMap AttrName EdhValue
      -> [EdhValue]
      -> [(AttrName, EdhValue)]
      -> EdhProc
    evalThePack !argsValues !kwargsValues [] [] =
      contEdhSTM
        -- restore original program state and return the eval-ed values
        $ exitEdhSTM pgs exit
        $ case argsValues of
            [val] | null kwargsValues -> val
            _ -> EdhArgsPack $ ArgsPack (reverse argsValues) kwargsValues
    evalThePack !argsValues !kwargsValues [] (kwExpr : kwargsExprs') =
      case kwExpr of
        (!kw, EdhExpr _ !expr _) ->
          evalExpr expr $ \(OriginalValue !val _ _) -> evalThePack
            argsValues
            (Map.insert kw val kwargsValues)
            []
            kwargsExprs'
        v -> throwEdh EvalError $ "Not an expr: " <> T.pack (show v)
    evalThePack !argsValues !kwargsValues (!argExpr : argsExprs') !kwargsExprs
      = case argExpr of
        EdhExpr _ !expr _ -> evalExpr expr $ \(OriginalValue !val _ _) ->
          evalThePack (val : argsValues) kwargsValues argsExprs' kwargsExprs
        v -> throwEdh EvalError $ "Not an expr: " <> T.pack (show v)
  if null kwargs && null args
    then exitEdhProc exit nil
    else
      contEdhSTM
      $ runEdhProc pgs
          { edh'context = callerCtx { callStack       = scopeCallStack
                                    , generatorCaller = Nothing
                                    , contextMatch    = true
                                    , contextStmt     = contextStmt callerCtx
                                    }
          }
      $ evalThePack [] Map.empty args
      $ Map.toList kwargs


-- | utility makeOp(lhExpr, opSym, rhExpr)
makeOpProc :: EdhProcedure
makeOpProc (ArgsPack args kwargs) !exit = do
  pgs <- ask
  if (not $ null kwargs)
    then throwEdh EvalError "No kwargs accepted by makeOp"
    else case args of
      [(EdhExpr _ !lhe _), EdhString op, (EdhExpr _ !rhe _)] -> contEdhSTM $ do
        expr <- edhExpr $ InfixExpr op lhe rhe
        exitEdhSTM pgs exit expr
      _ -> throwEdh EvalError $ "Invalid arguments to makeOp: " <> T.pack
        (show args)


-- | utility makeExpr(*args,**kwargs)
makeExprProc :: EdhProcedure
makeExprProc !apk !exit = case apk of
  ArgsPack [v] kwargs | Map.null kwargs -> exitEdhProc exit v
  _ -> exitEdhProc exit $ EdhArgsPack apk

