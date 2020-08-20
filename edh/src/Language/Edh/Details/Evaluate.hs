
module Language.Edh.Details.Evaluate where

import           Prelude
-- import           Debug.Trace

import           GHC.Conc                       ( unsafeIOToSTM )

import           Control.Exception
import           Control.Monad.State.Strict
import           Control.Concurrent
import           Control.Concurrent.STM

import           Data.Unique
import           Data.Maybe
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


-- | Get an attribute value from a target expression.
--
-- The target would be an object in most common cases, but can be some type of
-- value with virtual attributes, then one can be get as well.
getEdhAttr :: Expr -> AttrKey -> EdhTxExit -> EdhTxExit -> EdhTx
getEdhAttr !fromExpr !key !exitNoAttr !exit !ets = case fromExpr of

    -- give super objects the magical power to intercept
    -- attribute access on descendant objects, via `this` ref
  AttrExpr ThisRef ->
    let !this = edh'scope'this scope
        noMagic :: EdhTx
        noMagic _ets = lookupEdhObjAttr this key >>= \case
          (_    , EdhNil) -> exitEdhSTM ets exitNoAttr $ EdhObject this
          (this', !val  ) -> chkExit this' this val
    in  runEdhTx ets $ getObjAttrWSM (AttrByName "@<-") this key noMagic exit

  -- no super magic layer laid over access via `that` ref
  AttrExpr ThatRef ->
    let !that = edh'scope'that scope
    in  lookupEdhObjAttr that key >>= \case
          (_   , EdhNil) -> exitEdhSTM ets exitNoAttr $ EdhObject that
          (this, !val  ) -> chkExit this that val

  -- no super magic layer laid over access via `super` ref
  AttrExpr SuperRef ->
    let !this = edh'scope'this scope
    in  lookupEdhSuperAttr this key >>= \case
          (_    , EdhNil) -> exitEdhSTM ets exitNoAttr $ EdhObject this
          (this', !val  ) -> chkExit this' this' val

  _ -> runEdhTx ets $ evalExpr fromExpr $ \ !fromVal _ets -> case fromVal of

    -- give super objects the magical power to intercept
    -- attribute access on descendant objects, via obj ref
    EdhObject !obj ->
      let noMagic :: EdhTx
          noMagic _ets = lookupEdhObjAttr obj key >>= \case
            (_    , EdhNil) -> exitEdhSTM ets exitNoAttr $ EdhObject obj
            (this', !val  ) -> chkExit this' obj val
      in  runEdhTx ets $ getObjAttrWSM (AttrByName "@<-*") obj key noMagic exit

    -- getting attr from an apk
    EdhArgsPack (ArgsPack _ !kwargs) ->
      exitEdhSTM ets exit $ odLookupDefault EdhNil key kwargs

    -- virtual attrs by magic method from context
    _ -> case key of
      AttrByName !attrName -> do
        let !magicName =
              "__" <> T.pack (edhTypeNameOf fromVal) <> "_" <> attrName <> "__"
        lookupEdhCtxAttr scope (AttrByName magicName) >>= \case
          EdhProcedure (EdhMethod !mth) _ -> runEdhTx ets $ callEdhMethod
            (edh'scope'this scope)
            (edh'scope'that scope)
            mth
            (ArgsPack [fromVal] odEmpty)
            id
            exit
          _ -> exitEdhSTM ets exitNoAttr fromVal
      _ -> exitEdhSTM ets exitNoAttr fromVal

 where
  ctx   = edh'context ets
  scope = contextScope ctx

  chkExit :: Object -> Object -> EdhValue -> STM ()
  chkExit !rtnThis !rtnThat !rtnVal = case rtnVal of
    EdhBoundProc (EdhDescriptor !getter _) !this !that _ ->
      runEdhTx ets
        $ callEdhMethod this that getter (ArgsPack [] odEmpty) id exit
    EdhProcedure (EdhDescriptor !getter _) _ -> runEdhTx ets
      $ callEdhMethod rtnThis rtnThat getter (ArgsPack [] odEmpty) id exit
    EdhProcedure !callable !effOuter ->
      -- bind an unbound procedure to inferred `this` and `that`
      exitEdhSTM ets exit $ EdhBoundProc callable rtnThis rtnThat effOuter
    _ -> exitEdhSTM ets exit rtnVal


-- There're 2 tiers of magic happen during object attribute resolution in Edh.
--  *) a magical super controls its direct descendants in behaving as an object, by
--     intercepting the attr resolution
--  *) a metamagical super controls its direct descendants in behaving as a magical
--     super, by intercepting the magic method (as attr) resolution

edhMetaMagicSpell :: AttrKey
edhMetaMagicSpell = AttrByName "!<-"

-- | Try get an attribute from an object, with super magic
getObjAttrWSM :: AttrKey -> Object -> AttrKey -> EdhTx -> EdhTxExit -> EdhTx
getObjAttrWSM !magicSpell !obj !key !exitNoMagic !exitWithMagic !ets =
  (readTVar (edh'obj'supers obj) >>=) $ flip getViaSupers $ \case
    EdhNil -> runEdhTx ets exitNoMagic
    !val   -> exitEdhSTM ets exitWithMagic val
 where

  getViaSupers :: [Object] -> (EdhValue -> STM ()) -> STM ()
  getViaSupers [] !exit = exit nil
  getViaSupers (super : restSupers) !exit =
    runEdhTx ets
      $ getObjAttrWSM edhMetaMagicSpell super magicSpell noMetamagic
      $ \ !magicVal _ets -> case magicVal of
          EdhBoundProc (EdhMethod !magicMth) !this !that _ ->
            withMagicMethod magicMth this that
          EdhProcedure (EdhMethod !magicMth) _ ->
            withMagicMethod magicMth super super
          _ ->
            throwEdhSTM ets EvalError $ "Invalid magic method type: " <> T.pack
              (edhTypeNameOf magicVal)
   where

    noMetamagic :: EdhTx
    noMetamagic _ets = lookupEdhObjAttr super magicSpell >>= \case
      (_, EdhNil) -> getViaSupers restSupers exit
      (!super', EdhProcedure (EdhMethod !magicMth) _) ->
        withMagicMethod magicMth super' super
      (_, EdhBoundProc (EdhMethod !magicMth) !this !that _) ->
        withMagicMethod magicMth this that
      (_, !magicVal) ->
        throwEdhSTM ets EvalError $ "Invalid magic method type: " <> T.pack
          (edhTypeNameOf magicVal)

    withMagicMethod :: ProcDefi -> Object -> Object -> STM ()
    withMagicMethod !magicMth !this !that =
      runEdhTx ets
        $ callEdhMethod this
                        that
                        magicMth
                        (ArgsPack [attrKeyValue key] odEmpty)
                        id
        $ \ !magicRtn _ets -> case magicRtn of
            EdhDefault _ !exprDef !etsDef -> getViaSupers restSupers $ \case
              EdhNil ->
                runEdhTx (fromMaybe ets etsDef)
                  $ evalExpr exprDef
                  $ \ !defVal _ets -> exit defVal
              !betterEffVal -> exit betterEffVal
            EdhProcedure !callable !effOuter ->
              -- bind an unbound procedure to this super as `this`,
              -- and the obj as `that`
              exit $ EdhBoundProc callable super obj effOuter
            _ -> exit magicRtn


-- | Try set an attribute into an object, with super magic
setObjAttrWSM
  :: AttrKey -> Object -> AttrKey -> EdhValue -> EdhTx -> EdhTxExit -> EdhTx
setObjAttrWSM !magicSpell !obj !key !val !exitNoMagic !exitWithMagic !ets =
  (readTVar (edh'obj'supers obj) >>=) $ flip setViaSupers $ \case
    EdhNil -> runEdhTx ets exitNoMagic
    !rtn   -> exitEdhSTM ets exitWithMagic rtn
 where

  setViaSupers :: [Object] -> (EdhValue -> STM ()) -> STM ()
  setViaSupers [] !exit = exit nil
  setViaSupers (super : restSupers) !exit =
    runEdhTx ets
      $ getObjAttrWSM edhMetaMagicSpell super magicSpell noMetamagic
      $ \ !magicVal _ets -> case magicVal of
          EdhBoundProc (EdhMethod !magicMth) !this !that _ ->
            withMagicMethod magicMth this that
          EdhProcedure (EdhMethod !magicMth) _ ->
            withMagicMethod magicMth super super
          _ ->
            throwEdhSTM ets EvalError $ "Invalid magic method type: " <> T.pack
              (edhTypeNameOf magicVal)
   where

    noMetamagic :: EdhTx
    noMetamagic _ets = lookupEdhObjAttr super magicSpell >>= \case
      (_, EdhNil) -> setViaSupers restSupers exit
      (!super', EdhProcedure (EdhMethod !magicMth) _) ->
        withMagicMethod magicMth super' super
      (_, EdhBoundProc (EdhMethod !magicMth) !this !that _) ->
        withMagicMethod magicMth this that
      (_, !magicVal) ->
        throwEdhSTM ets EvalError $ "Invalid magic method type: " <> T.pack
          (edhTypeNameOf magicVal)

    withMagicMethod :: ProcDefi -> Object -> Object -> STM ()
    withMagicMethod !magicMth !this !that =
      runEdhTx ets
        $ callEdhMethod this
                        that
                        magicMth
                        (ArgsPack [attrKeyValue key, val] odEmpty)
                        id
        $ \ !magicRtn _ets -> case magicRtn of
            EdhDefault _ !exprDef !etsDef -> setViaSupers restSupers $ \case
              EdhNil ->
                runEdhTx (fromMaybe ets etsDef)
                  $ evalExpr exprDef
                  $ \ !defVal _ets -> exit defVal
              !betterEffVal -> exit betterEffVal
            -- nil return value implies no magic, it doesn't mean that
            EdhNil -> exit (EdhNamedValue "<magic-set>" EdhNil)
            _      -> exit magicRtn


-- | Set an attribute value to a target expression.
--
-- The target would be an object in most common cases, but can be some type of
-- value with virtual attributes, but currently all virtual attributes are
-- readonly, not mutable virtual attribute supported yet.
setEdhAttr :: Expr -> AttrKey -> EdhValue -> EdhTxExit -> EdhTx
setEdhAttr !tgtExpr !key !val !exit !ets = case tgtExpr of

  -- give super objects the magical power to intercept
  -- attribute assignment to descendant objects, via `this` ref
  AttrExpr ThisRef ->
    let !this = edh'scope'this scope
        noMagic :: EdhTx
        noMagic _ets = setObjAttr ets this key val
          $ \ !valSet -> exitEdhSTM ets exit valSet
    in  runEdhTx ets
          $ setObjAttrWSM (AttrByName "<-@") this key val noMagic exit

  -- no magic layer laid over assignment via `that` ref
  AttrExpr ThatRef ->
    let !that = edh'scope'that scope
    in  setObjAttr ets that key val $ \ !valSet -> exitEdhSTM ets exit valSet

  -- not allowing assignment via super
  AttrExpr SuperRef -> throwEdhSTM ets EvalError "can not assign via super"

  _ -> runEdhTx ets $ evalExpr tgtExpr $ \ !tgtVal _ets -> case tgtVal of

    -- give super objects the magical power to intercept
    -- attribute assignment to descendant objects, via obj ref
    EdhObject !tgtObj ->
      let noMagic :: EdhTx
          noMagic _ets = setObjAttr ets tgtObj key val
            $ \ !valSet -> exitEdhSTM ets exit valSet
      in  runEdhTx ets
            $ setObjAttrWSM (AttrByName "*<-@") tgtObj key val noMagic exit

    -- no virtual attribute supported yet
    _ ->
      throwEdhSTM ets EvalError
        $  "Invalid assignment target, it's a "
        <> T.pack (edhTypeNameOf tgtVal)
        <> ": "
        <> T.pack (show tgtVal)

 where
  ctx   = edh'context ets
  scope = contextScope ctx


setObjAttr
  :: EdhThreadState
  -> Object
  -> AttrKey
  -> EdhValue
  -> (EdhValue -> STM ())
  -> STM ()
setObjAttr !ets !obj !key !val !exit = lookupEdhObjAttr obj key >>= \case
  (_, EdhNil) -> writeAttr
  (!this', EdhProcedure (EdhDescriptor _getter (Just !setter)) _) ->
    callSetter this' obj setter
  (_, EdhBoundProc (EdhDescriptor _getter (Just !setter)) this that _) ->
    callSetter this that setter
  (_, EdhProcedure (EdhDescriptor !getter Nothing) _) -> readonly getter
  (_, EdhBoundProc (EdhDescriptor !getter Nothing) _ _ _) -> readonly getter
  _ -> writeAttr
 where
  callSetter !this !that !setter =
    let !args = case val of
          EdhNil -> []
          _      -> [val]
    in  runEdhTx ets
          $ callEdhMethod this that setter (ArgsPack args odEmpty) id
          $ \ !propRtn _ets -> exit propRtn
  writeAttr = case edh'obj'store obj of
    HashStore  !hs             -> iopdInsert key val hs >> exit val
    ClassStore (Class _ !cs _) -> iopdInsert key val cs >> exit val
    HostStore _ ->
      throwEdhSTM ets UsageError
        $  "no such property `"
        <> T.pack (show key)
        <> "` on host object of class "
        <> objClassName obj
  readonly !getter =
    throwEdhSTM ets UsageError
      $  "property `"
      <> T.pack (show $ edh'procedure'name getter)
      <> "` of class "
      <> objClassName obj
      <> " is readonly"


-- | Assign an evaluated value to a target expression
--
-- Note the calling procedure should declare in-tx state in evaluating the
-- right-handle value as well as running this, so the evaluation of the
-- right-hand value as well as the writting to the target entity are done
-- within the same tx, thus for atomicity of the whole assignment.
assignEdhTarget :: Expr -> EdhValue -> EdhTxExit -> EdhTx
assignEdhTarget !lhExpr !rhVal !exit !ets = case lhExpr of
  AttrExpr !addr -> case addr of
    -- silently drop value assigned to single underscore
    DirectRef (NamedAttr "_") -> exitEdhSTM ets exit nil
    -- no magic imposed to direct assignment in a (possibly class) proc
    DirectRef !addr'          -> resolveEdhAttrAddr ets addr' $ \ !key -> do
      if edh'ctx'eff'defining ctx
        then defEffectInto esScope key
        else iopdInsert key rhVal esScope

      exitWithChkExportTo (edh'scope'this scope) key rhVal
      -- ^ exporting within a method procedure actually adds the artifact to
      -- its owning object's export table, besides changing the mth proc's
      -- scope, maybe confusing in some cases, need more thoughts on it

    -- special case, assigning with `this.v=x` `that.v=y`, handle exports and
    -- effect definition
    IndirectRef (AttrExpr ThisRef) !addr' ->
      let this = edh'scope'this scope
      in  resolveEdhAttrAddr ets addr' $ \ !key -> if edh'ctx'eff'defining ctx
            then do
              defEffIntoObj this key
              exitWithChkExportTo this key rhVal
            else setObjAttr ets this key rhVal
              $ \ !valSet -> exitWithChkExportTo this key valSet
    IndirectRef (AttrExpr ThatRef) !addr' ->
      let that = edh'scope'that scope
      in  resolveEdhAttrAddr ets addr' $ \ !key -> if edh'ctx'eff'defining ctx
            then do
              defEffIntoObj that key
              exitWithChkExportTo that key rhVal
            else setObjAttr ets that key rhVal
              $ \ !valSet -> exitWithChkExportTo that key valSet
    -- assign to an addressed attribute
    IndirectRef !tgtExpr !addr' -> resolveEdhAttrAddr ets addr'
      $ \ !key -> runEdhTx ets $ setEdhAttr tgtExpr key rhVal exit
    -- god forbidden things
    ThisRef  -> throwEdhSTM ets EvalError "can not assign to this"
    ThatRef  -> throwEdhSTM ets EvalError "can not assign to that"
    SuperRef -> throwEdhSTM ets EvalError "can not assign to super"
  -- dereferencing attribute assignment
  InfixExpr "@" !tgtExpr !addrRef ->
    runEdhTx ets $ evalExpr addrRef $ \ !addrVal _ets ->
      case edhUltimate addrVal of
        EdhExpr _ (AttrExpr (DirectRef !addr)) _ -> resolveEdhAttrAddr ets addr
          $ \ !key -> runEdhTx ets $ setEdhAttr tgtExpr key rhVal exit
        EdhString !attrName ->
          runEdhTx ets $ setEdhAttr tgtExpr (AttrByName attrName) rhVal exit
        EdhSymbol !sym ->
          runEdhTx ets $ setEdhAttr tgtExpr (AttrBySym sym) rhVal exit
        _ ->
          throwEdhSTM ets EvalError
            $  "invalid attribute reference type - "
            <> T.pack (edhTypeNameOf addrVal)
  !x ->
    throwEdhSTM ets EvalError
      $  "invalid left hand expression for assignment: "
      <> T.pack (show x)
 where
  !ctx    = edh'context ets
  scope   = contextScope ctx
  esScope = edh'scope'entity scope

  exitWithChkExportTo :: Object -> AttrKey -> EdhValue -> STM ()
  exitWithChkExportTo !obj !artKey !artVal = do
    when (edh'ctx'exporting ctx) $ case edh'obj'store obj of
      HashStore  !hs             -> expInto hs artKey artVal
      ClassStore (Class _ !cs _) -> expInto cs artKey artVal
      HostStore _ ->
        throwEdhSTM ets UsageError
          $  "no way exporting to a host object of class "
          <> objClassName obj
    exitEdhSTM ets exit artVal
  expInto :: EntityStore -> AttrKey -> EdhValue -> STM ()
  expInto !es !artKey !artVal =
    iopdLookup (AttrByName edhExportsMagicName) es >>= \case
      Just (EdhDict (Dict _ !ds)) -> iopdInsert (attrKeyValue artKey) artVal ds
      _                           -> do
        d <- EdhDict <$> createEdhDict [(attrKeyValue artKey, artVal)]
        iopdInsert (AttrByName edhExportsMagicName) d es

  defEffIntoObj :: Object -> AttrKey -> STM ()
  defEffIntoObj !obj !key = case edh'obj'store obj of
    HashStore  !hs             -> defEffectInto hs key
    ClassStore (Class _ !cs _) -> defEffectInto cs key
    HostStore _ ->
      throwEdhSTM ets UsageError
        $  "no way defining effects into a host object of class "
        <> objClassName obj
  defEffectInto :: EntityStore -> AttrKey -> STM ()
  defEffectInto !es !artKey =
    iopdLookup (AttrByName edhEffectsMagicName) es >>= \case
      Just (EdhDict (Dict _ !effDS)) ->
        iopdInsert (attrKeyValue artKey) rhVal effDS
      _ -> do
        !d <- EdhDict <$> createEdhDict [(attrKeyValue artKey, rhVal)]
        iopdInsert (AttrByName edhEffectsMagicName) d es


-- | Creating an Edh object from a class, without calling any `__init__()`
-- method.
--
-- Note no duplicate object instance will be created even if the class
-- inheritance hierarchy forms diamond shapes.
createEdhObject
  :: EdhThreadState -> Object -> ArgsPack -> (Object -> STM ()) -> STM ()
createEdhObject !ets !clsObj !apk !exitEnd = do
  !mroEnd <- iopdEmpty
  createOne mroEnd clsObj exitEnd
 where

  createOne :: IOPD Object Object -> Object -> (Object -> STM ()) -> STM ()
  createOne !mroEnd !clsCurr !exit = iopdLookup clsCurr mroEnd >>= \case
    Just !objCurr -> exit objCurr
    Nothing       -> case edh'obj'store clsCurr of
      ClassStore (Class _ _ !allocator) -> allocator ets apk $ \ !es -> do
        !oid       <- unsafeIOToSTM newUnique
        !supersVar <- newTVar []
        let !objCurr = Object oid es clsCurr supersVar
        iopdInsert clsCurr objCurr mroEnd

        !mroSupers    <- iopdEmpty
        !superClasses <- readTVar $ edh'obj'supers clsCurr
        createSupers mroEnd mroSupers superClasses $ do
          fmap snd <$> iopdToList mroSupers >>= writeTVar supersVar
          exit objCurr
      _ ->
        throwEdhSTM ets UsageError
          $  "can not create object from an object of class "
          <> objClassName clsCurr

  createSupers
    :: IOPD Object Object -> IOPD Object Object -> [Object] -> STM () -> STM ()
  createSupers _ _ [] !exit = exit
  createSupers !mroEnd !mroSupers (superCls : restSupers) !exit =
    createOne mroEnd superCls $ \ !superObj -> do
      iopdInsert superCls superObj mroSupers
      createSupers mroEnd mroSupers restSupers exit


-- | Construct an Edh object from a class.
--
-- All `__init__()` methods provided by the specified class, and its super
-- classes will be called with the specified apk, and for each call:
--
-- - contextual `that` will always be the end object just created, unless
--   one `__init__()` method itself being already bound to sth else, which
--   is unusual
--
-- - contextual `this` will be the object instance corresponding to the class
--   providing the respective `__init__()` method, unless the provided 
--   `__init__()` method itself being already bound to sth else, which is
--   unusual
--
-- Note no duplicate object instance will be created even if the class
-- inheritance hierarchy forms diamond shapes.
constructEdhObject :: Object -> ArgsPack -> (Object -> EdhTx) -> EdhTx
constructEdhObject !clsObj !apk !exit !ets =
  createEdhObject ets clsObj apk $ \ !obj -> do
    let
      callInit :: [Object] -> STM ()
      callInit [] = runEdhTx ets $ exit obj
      callInit (o : rest) =
        lookupEdhSelfAttr o (AttrByName "__init__") >>= \case
          EdhNil -> callInit rest
          EdhProcedure (EdhMethod !mthInit) _ ->
            runEdhTx ets
              $ callEdhMethod o obj mthInit apk id
              $ \_initResult _ets -> callInit rest
          EdhBoundProc (EdhMethod !mthInit) !this !that _ ->
            runEdhTx ets
              $ callEdhMethod this that mthInit apk id
              $ \_initResult _ets -> callInit rest
          !badInitMth ->
            throwEdhSTM ets UsageError
              $  "invalid __init__ method of type: "
              <> T.pack (edhTypeNameOf badInitMth)
    callInit =<< (obj :) <$> readTVar (edh'obj'supers obj)


callEdhOperator
  :: Object
  -> Object
  -> ProcDefi
  -> Maybe EdhValue
  -> [EdhValue]
  -> EdhTxExit
  -> EdhTx
callEdhOperator !this !that !mth !prede !args !exit =
  case edh'procedure'body $ edh'procedure'decl mth of

    -- calling a host operator procedure
    Right !hp -> \ !ets -> do
      -- a host procedure views the same scope entity as of the caller's
      -- call frame
      let ctx       = edh'context ets
          scope     = contextScope ctx

          !mthScope = (lexicalScopeOf mth)
            { edh'scope'entity = edh'scope'entity scope
            , edh'scope'this   = this
            , edh'scope'that   = that
            , edh'scope'proc   = mth
            , edh'scope'caller = edh'ctx'stmt ctx
            }
          !mthCtx = ctx { edh'ctx'stack        = mthScope <| edh'ctx'stack ctx
                        , edh'ctx'genr'caller  = Nothing
                        , edh'ctx'match        = true
                        , edh'ctx'pure         = False
                        , edh'ctx'exporting    = False
                        , edh'ctx'eff'defining = False
                        }
          !etsMth = ets { edh'context = mthCtx }
      runEdhTx etsMth $ hp (ArgsPack args odEmpty) $ \ !hpRtn ->
        -- a host operator is responsible to not return meaningless values
        -- like return wrapper, or e.g. continue/break etc.
        edhSwitchState ets $ exitEdhTx exit hpRtn

    -- calling an Edh operator procedure
    Left !pb -> callEdhOperator' this that mth prede pb args $ exit

callEdhOperator'
  :: Object
  -> Object
  -> ProcDefi
  -> Maybe EdhValue
  -> StmtSrc
  -> [EdhValue]
  -> EdhTxExit
  -> EdhTx
callEdhOperator' !this !that !mth !prede !mth'body !args !exit !ets =
  recvEdhArgs ets
              recvCtx
              (edh'procedure'args $ edh'procedure'decl mth)
              (ArgsPack args odEmpty)
    $ \ !ed -> do
        !es <- iopdFromList $ odToList ed
        let !mthScope = (lexicalScopeOf mth) { edh'scope'entity = es
                                             , edh'scope'this   = this
                                             , edh'scope'that   = that
                                             , edh'scope'proc   = mth
                                             , edh'scope'caller = edh'ctx'stmt
                                               ctx
                                             }
            !mthCtx = ctx { edh'ctx'stack        = mthScope <| edh'ctx'stack ctx
                          , edh'ctx'genr'caller  = Nothing
                          , edh'ctx'match        = true
                          , edh'ctx'stmt         = mth'body
                          , edh'ctx'pure         = False
                          , edh'ctx'exporting    = False
                          , edh'ctx'eff'defining = False
                          }
            !etsMth = ets { edh'context = mthCtx }
        case prede of
          Nothing      -> pure ()
          -- put the overridden predecessor operator into the overriding
          -- operator procedure's runtime scope
          Just !predOp -> iopdInsert (edh'procedure'name mth) predOp es
        runEdhTx etsMth $ evalStmt mth'body $ \ !mthRtn ->
          edhSwitchState ets $ exitEdhTx exit $ case edhDeCaseClose mthRtn of
            EdhReturn !rtnVal -> rtnVal
            -- todo translate break/continue to nil here?
            !rtnVal           -> rtnVal
 where
  !ctx     = edh'context ets
  !recvCtx = ctx
    { edh'ctx'stack        = (lexicalScopeOf mth) { edh'scope'this = this
                                                  , edh'scope'that = that
                                                  }
                               :| []
    , edh'ctx'genr'caller  = Nothing
    , edh'ctx'match        = true
    , edh'ctx'stmt         = mth'body
    , edh'ctx'pure         = False
    , edh'ctx'exporting    = False
    , edh'ctx'eff'defining = False
    }


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
  :: EdhThreadState
  -> Context
  -> ArgsReceiver
  -> ArgsPack
  -> (OrderedDict AttrKey EdhValue -> STM ())
  -> STM ()
recvEdhArgs !etsCaller !recvCtx !argsRcvr apk@(ArgsPack !posArgs !kwArgs) !exit
  = case argsRcvr of
    PackReceiver argRcvrs -> iopdEmpty >>= \ !em ->
      let
        go :: [ArgReceiver] -> ArgsPack -> STM ()
        go [] !apk' =
          woResidual apk' $ iopdSnapshot em >>= edhDoSTM etsCaller . exit
        go (r : rest) !apk' =
          recvFromPack apk' em r $ \ !apk'' -> go rest apk''
      in
        go argRcvrs apk
    SingleReceiver argRcvr -> iopdEmpty >>= \ !em ->
      recvFromPack apk em argRcvr $ \ !apk' ->
        woResidual apk' $ iopdSnapshot em >>= edhDoSTM etsCaller . exit
    WildReceiver -> if null posArgs
      then edhDoSTM etsCaller $ exit kwArgs
      else
        throwEdhSTM etsCaller EvalError
        $  "Unexpected "
        <> T.pack (show $ length posArgs)
        <> " positional argument(s) to wild receiver"

 where

    -- execution of the args receiving always in a tx for atomicity, and
    -- in the specified receiving (should be callee's outer) context
  !etsRecv = etsCaller { edh'in'tx = True, edh'context = recvCtx }

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
        resolveEdhAttrAddr etsRecv argAddr $ \argKey ->
          resolveArgValue argKey argDefault $ \(argVal, posArgs'', kwArgs'') ->
            case argTgtAddr of
              Nothing -> do
                iopdInsert argKey argVal em
                exit' (ArgsPack posArgs'' kwArgs'')
              Just (DirectRef !addr) -> case addr of
                NamedAttr "_" -> -- drop
                  exit' (ArgsPack posArgs'' kwArgs'')
                NamedAttr !attrName -> do -- simple rename
                  iopdInsert (AttrByName attrName) argVal em
                  exit' (ArgsPack posArgs'' kwArgs'')
                SymbolicAttr !symName -> -- todo support this ?
                  throwEdhSTM etsCaller UsageError
                    $  "Do you mean `this.@"
                    <> symName
                    <> "` instead ?"
              Just addr@(IndirectRef _ _) -> do
                -- do assignment in callee's context, and return to caller's afterwards
                runEdhTx etsRecv
                  $ assignEdhTarget (AttrExpr addr) argVal
                  $ \_assignResult _ets -> exit' (ArgsPack posArgs'' kwArgs'')
              !tgt ->
                throwEdhSTM etsCaller UsageError
                  $  "Invalid argument retarget: "
                  <> T.pack (show tgt)
   where
    resolveArgValue
      :: AttrKey
      -> Maybe Expr
      -> ((EdhValue, [EdhValue], OrderedDict AttrKey EdhValue) -> STM ())
      -> STM ()
    resolveArgValue !argKey !argDefault !exit'' = do
      let (inKwArgs, kwArgs'') = odTakeOut argKey kwArgs'
      case inKwArgs of
        Just argVal -> exit'' (argVal, posArgs', kwArgs'')
        _           -> case posArgs' of
          (posArg : posArgs'') -> exit'' (posArg, posArgs'', kwArgs'')
          []                   -> case argDefault of
            -- always eval the default value atomically in callee's contex
            Just !defaultExpr ->
              runEdhTx etsRecv $ evalExpr defaultExpr $ \ !val _ets ->
                exit'' (edhDeCaseClose val, posArgs', kwArgs'')
            _ ->
              throwEdhSTM etsCaller UsageError $ "Missing argument: " <> T.pack
                (show argKey)
  woResidual :: ArgsPack -> STM () -> STM ()
  woResidual (ArgsPack !posResidual !kwResidual) !exit'
    | not (null posResidual)
    = throwEdhSTM etsCaller UsageError
      $  "Extraneous "
      <> T.pack (show $ length posResidual)
      <> " positional argument(s)"
    | not (odNull kwResidual)
    = throwEdhSTM etsCaller UsageError
      $  "Extraneous keyword arguments: "
      <> T.pack (unwords (show <$> odKeys kwResidual))
    | otherwise
    = exit'


-- | Pack args as expressions, normally in preparation of calling another
-- interpreter procedure
packEdhExprs :: EdhThreadState -> ArgsPacker -> (ArgsPack -> STM ()) -> STM ()
packEdhExprs !ets !pkrs !pkExit = do
  kwIOPD <- iopdEmpty
  let
    pkExprs :: [ArgSender] -> ([EdhValue] -> STM ()) -> STM ()
    pkExprs []       !exit = exit []
    pkExprs (x : xs) !exit = case x of
      UnpackPosArgs _ ->
        throwEdhSTM ets EvalError "unpack to expr not supported yet"
      UnpackKwArgs _ ->
        throwEdhSTM ets EvalError "unpack to expr not supported yet"
      UnpackPkArgs _ ->
        throwEdhSTM ets EvalError "unpack to expr not supported yet"
      SendPosArg !argExpr -> pkExprs xs $ \ !posArgs -> do
        !xu <- unsafeIOToSTM newUnique
        exit (EdhExpr xu argExpr "" : posArgs)
      SendKwArg !kwAddr !argExpr ->
        resolveEdhAttrAddr ets kwAddr $ \ !kwKey -> do
          xu <- unsafeIOToSTM newUnique
          iopdInsert kwKey (EdhExpr xu argExpr "") kwIOPD
          pkExprs xs $ \ !posArgs' -> exit posArgs'
  pkExprs pkrs $ \ !args ->
    iopdSnapshot kwIOPD >>= \ !kwargs -> pkExit $ ArgsPack args kwargs


-- | Pack args as caller, normally in preparation of calling another procedure
packEdhArgs :: EdhThreadState -> ArgsPacker -> (ArgsPack -> STM ()) -> STM ()
packEdhArgs !ets !argSenders !pkExit = do
  !kwIOPD <- iopdEmpty
  let
    pkArgs :: [ArgSender] -> ([EdhValue] -> STM ()) -> STM ()
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
          runEdhTx etsPacking $ evalExpr posExpr $ \ !val _ets ->
            case edhUltimate val of
              (EdhArgsPack (ArgsPack !posArgs _kwArgs)) ->
                pkArgs xs $ \ !posArgs' -> exit (posArgs ++ posArgs')
              (EdhPair !k !v) ->
                pkArgs xs $ \ !posArgs -> exit ([k, noneNil v] ++ posArgs)
              (EdhList (List _ !l)) -> pkArgs xs $ \ !posArgs -> do
                ll <- readTVar l
                exit ((noneNil <$> ll) ++ posArgs)
              _ ->
                throwEdhSTM ets EvalError
                  $  "Can not unpack args from a "
                  <> T.pack (edhTypeNameOf val)
                  <> ": "
                  <> T.pack (show val)
        UnpackKwArgs !kwExpr ->
          runEdhTx etsPacking $ evalExpr kwExpr $ \ !val _ets ->
            case edhUltimate val of
              EdhArgsPack (ArgsPack _posArgs !kwArgs') -> do
                iopdUpdate (odToList kwArgs') kwIOPD
                pkArgs xs $ \ !posArgs' -> exit posArgs'
              (EdhPair !k !v) ->
                edhVal2Kw
                    k
                    (  throwEdhSTM ets UsageError
                    $  "Invalid keyword type: "
                    <> T.pack (edhTypeNameOf k)
                    )
                  $ \ !kw -> do
                      iopdInsert kw (noneNil $ edhDeCaseClose v) kwIOPD
                      pkArgs xs $ \ !posArgs -> exit posArgs
              (EdhDict (Dict _ !ds)) -> do
                !dkvl <- iopdToList ds
                dictKvs2Kwl dkvl $ \ !kvl -> do
                  iopdUpdate kvl kwIOPD
                  pkArgs xs $ \ !posArgs -> exit posArgs
              _ ->
                throwEdhSTM ets EvalError
                  $  "Can not unpack kwargs from a "
                  <> T.pack (edhTypeNameOf val)
                  <> ": "
                  <> T.pack (show val)
        UnpackPkArgs !pkExpr ->
          runEdhTx etsPacking $ evalExpr pkExpr $ \ !val _ets ->
            case edhUltimate val of
              (EdhArgsPack (ArgsPack !posArgs !kwArgs')) -> do
                iopdUpdate (odToList kwArgs') kwIOPD
                pkArgs xs $ \ !posArgs' -> exit (posArgs ++ posArgs')
              _ ->
                throwEdhSTM ets EvalError
                  $  "Can not unpack apk from a "
                  <> T.pack (edhTypeNameOf val)
                  <> ": "
                  <> T.pack (show val)
        SendPosArg !argExpr ->
          runEdhTx etsPacking $ evalExpr argExpr $ \ !val _ets -> pkArgs xs
            $ \ !posArgs -> exit (noneNil (edhDeCaseClose val) : posArgs)
        SendKwArg !kwAddr !argExpr ->
          runEdhTx etsPacking $ evalExpr argExpr $ \ !val _ets -> case kwAddr of
            NamedAttr "_" ->  -- silently drop the value to keyword of single
              -- underscore, the user may just want its side-effect
              pkArgs xs $ \ !posArgs -> exit posArgs
            _ -> resolveEdhAttrAddr ets kwAddr $ \ !kwKey -> do
              iopdInsert kwKey (noneNil $ edhDeCaseClose val) kwIOPD
              pkArgs xs $ \ !posArgs -> exit posArgs
  pkArgs argSenders $ \ !posArgs -> do
    !kwArgs <- iopdSnapshot kwIOPD
    -- restore original tx state after args packed
    pkExit $ ArgsPack posArgs kwArgs
 where
  !etsPacking = ets {
                      -- make sure values in a pack are evaluated in same tx
                      edh'in'tx   = True
                      -- discourage artifact definition during args packing
                    , edh'context = (edh'context ets) { edh'ctx'pure = True }
                    }

-- Each Edh call is carried out in 2 phases, the preparation and the actual
-- call execution. This is necessary to support the `go/defer` mechanism,
-- where the preparation and call execution happen in different contexts.
-- 
-- - In case of `go`, the preparation happens in the forker thread, while the
--   actual call is executed in the forked descendant thread
--
-- - In case of `defer`, the preparation happens when it's scheduled, while
--   the actual call is executed when then thread is about to terminate
--
-- - The call is executed subsequently in the same thread, immediately after
--   it's prepared in other cases

-- | Prepare an Edh call
edhPrepareCall
  :: EdhThreadState -- ets to prepare the call
  -> EdhValue       -- callee value
  -> ArgsPacker     -- specification for the arguments pack
  -> ((EdhTxExit -> EdhTx) -> STM ()) -- callback to receive the prepared call
  -> STM ()
edhPrepareCall !etsCallPrep !calleeVal !argsSndr !callMaker = case calleeVal of
  EdhProcedure EdhIntrpr{} _ -> packEdhExprs etsCallPrep argsSndr
    $ \ !apk -> edhPrepareCall' etsCallPrep calleeVal apk callMaker
  EdhBoundProc EdhIntrpr{} _ _ _ -> packEdhExprs etsCallPrep argsSndr
    $ \ !apk -> edhPrepareCall' etsCallPrep calleeVal apk callMaker
  _ -> packEdhArgs etsCallPrep argsSndr
    $ \ !apk -> edhPrepareCall' etsCallPrep calleeVal apk callMaker

-- | Prepare an Edh call
edhPrepareCall'
  :: EdhThreadState -- ets to prepare the call
  -> EdhValue       -- callee value
  -> ArgsPack       -- packed arguments
  -> ((EdhTxExit -> EdhTx) -> STM ()) -- callback to receive the prepared call
  -> STM ()
edhPrepareCall' !etsCallPrep !calleeVal apk@(ArgsPack !args !kwargs) !callMaker
  = case calleeVal of
    EdhBoundProc !callee !this !that !effOuter ->
      callCallable callee this that
        $ flip (maybe id) effOuter
        $ \ !outerScope !s -> s { edh'effects'stack = outerScope }
    EdhProcedure !callee !effOuter ->
      callCallable callee (edh'scope'this scope) (edh'scope'that scope)
        $ flip (maybe id) effOuter
        $ \ !outerScope !s -> s { edh'effects'stack = outerScope }

    (EdhObject !obj) -> case edh'obj'store obj of
      -- calling a class
      ClassStore{} -> callMaker $ \ !exit -> constructEdhObject obj apk
        $ \ !instObj !ets -> exitEdhSTM ets exit $ EdhObject instObj
      -- calling an object
      _ -> lookupEdhObjAttr obj (AttrByName "__call__") >>= \(!this', !mth) ->
        case mth of
          EdhBoundProc !callee !this !that !effOuter ->
            callCallable callee this that
              $ flip (maybe id) effOuter
              $ \ !outerScope !s -> s { edh'effects'stack = outerScope }
          EdhProcedure !callee !effOuter ->
            callCallable callee this' obj
              $ flip (maybe id) effOuter
              $ \ !outerScope !s -> s { edh'effects'stack = outerScope }
          _ -> throwEdhSTM etsCallPrep EvalError "No __call__ method on object"

    _ ->
      throwEdhSTM etsCallPrep EvalError
        $  "Can not call a "
        <> T.pack (edhTypeNameOf calleeVal)
        <> ": "
        <> T.pack (show calleeVal)

 where
  scope = contextScope $ edh'context etsCallPrep

  callCallable :: EdhCallable -> Object -> Object -> (Scope -> Scope) -> STM ()
  callCallable !callee !this !that !scopeMod = case callee of

    -- calling a method procedure
    EdhMethod !mth ->
      callMaker $ \ !exit -> callEdhMethod this that mth apk scopeMod exit

    -- calling an interpreter procedure
    EdhIntrpr !mth -> do
      -- an Edh interpreter proc needs a `callerScope` as its 1st arg,
      -- while a host interpreter proc doesn't.
      apk' <- case edh'procedure'body $ edh'procedure'decl mth of
        Right _ -> return apk
        Left  _ -> do
          let callerCtx = edh'context etsCallPrep
          !argCallerScope <- mkScopeWrapper callerCtx $ contextScope callerCtx
          return $ ArgsPack (EdhObject argCallerScope : args) kwargs
      callMaker $ \ !exit -> callEdhMethod this that mth apk' scopeMod exit

    -- calling a producer procedure
    EdhPrducr !mth -> case edh'procedure'body $ edh'procedure'decl mth of
      Right _ ->
        throwEdhSTM etsCallPrep EvalError "bug: host producer procedure"
      Left !pb -> case edhUltimate <$> odLookup (AttrByName "outlet") kwargs of
        Nothing -> do
          outlet <- newEventSink
          callMaker $ \exit -> launchEventProducer exit outlet $ callEdhMethod'
            Nothing
            this
            that
            mth
            pb
            (  ArgsPack args
            $  odFromList
            $  odToList kwargs
            ++ [(AttrByName "outlet", EdhSink outlet)]
            )
            scopeMod
            endOfEdh
        Just (EdhSink !outlet) -> callMaker $ \exit ->
          launchEventProducer exit outlet $ callEdhMethod'
            Nothing
            this
            that
            mth
            pb
            (ArgsPack args kwargs)
            scopeMod
            endOfEdh
        Just !badVal ->
          throwEdhSTM etsCallPrep UsageError
            $  "The value passed to a producer as `outlet` found to be a "
            <> T.pack (edhTypeNameOf badVal)

    -- calling a generator
    (EdhGnrtor _) -> throwEdhSTM
      etsCallPrep
      EvalError
      "Can only call a generator method by for-from-do loop"

    _ ->
      throwEdhSTM etsCallPrep EvalError
        $  "`edhPrepareCall` can not be used to call a "
        <> T.pack (show callee)


callEdhMethod
  :: Object
  -> Object
  -> ProcDefi
  -> ArgsPack
  -> (Scope -> Scope)
  -> EdhTxExit
  -> EdhTx
callEdhMethod !this !that !mth !apk !scopeMod !exit !etsCaller = do
  let callerCtx   = edh'context etsCaller
      callerScope = contextScope callerCtx
  case edh'procedure'body $ edh'procedure'decl mth of

    -- calling a host method procedure
    Right !hp -> do
      -- a host procedure views the same scope entity as of the caller's
      -- call frame
      let !mthScope = scopeMod $ (lexicalScopeOf mth)
            { edh'scope'entity = edh'scope'entity callerScope
            , edh'scope'this   = this
            , edh'scope'that   = that
            , edh'scope'proc   = mth
            , edh'scope'caller = edh'ctx'stmt callerCtx
            }
          !mthCtx = callerCtx
            { edh'ctx'stack        = mthScope <| edh'ctx'stack callerCtx
            , edh'ctx'genr'caller  = Nothing
            , edh'ctx'match        = true
            , edh'ctx'pure         = False
            , edh'ctx'exporting    = False
            , edh'ctx'eff'defining = False
            }
          !etsMth = etsCaller { edh'context = mthCtx }
      runEdhTx etsMth $ hp apk $ \ !val -> edhSwitchState etsCaller $ exit val
      -- return whatever the result a host procedure returned

    -- calling an Edh method procedure
    Left !pb ->
      runEdhTx etsCaller
        $ callEdhMethod' Nothing this that mth pb apk scopeMod
        $ \ !mthRtn -> case mthRtn of
          -- explicit return
            EdhReturn rtnVal -> exitEdhTx exit rtnVal
            -- no explicit return
            _                -> exitEdhTx exit mthRtn

callEdhMethod'
  :: Maybe EdhGenrCaller
  -> Object
  -> Object
  -> ProcDefi
  -> StmtSrc
  -> ArgsPack
  -> (Scope -> Scope)
  -> EdhTxExit
  -> EdhTx
callEdhMethod' !gnr'caller !this !that !mth !mth'body !apk !scopeMod !exit !etsCaller
  = recvEdhArgs etsCaller
                recvCtx
                (edh'procedure'args $ edh'procedure'decl mth)
                apk
    $ \ !ed -> do
        !esScope <- iopdFromList (odToList ed)
        let !mthScope = scopeMod $ (lexicalScopeOf mth)
              { edh'scope'entity = esScope
              , edh'scope'this   = this
              , edh'scope'that   = that
              , edh'scope'proc   = mth
              , edh'scope'caller = edh'ctx'stmt callerCtx
              }
            !mthCtx = callerCtx
              { edh'ctx'stack        = mthScope <| edh'ctx'stack callerCtx
              , edh'ctx'genr'caller  = gnr'caller
              , edh'ctx'match        = true
              , edh'ctx'stmt         = mth'body
              , edh'ctx'pure         = False
              , edh'ctx'exporting    = False
              , edh'ctx'eff'defining = False
              }
            !etsMth = etsCaller { edh'context = mthCtx }
        runEdhTx etsMth $ evalStmt mth'body $ \ !mthRtn ->
          edhSwitchState etsCaller $ exit mthRtn
 where
  !callerCtx = edh'context etsCaller
  !recvCtx   = callerCtx
    { edh'ctx'stack        = (lexicalScopeOf mth) { edh'scope'this = this
                                                  , edh'scope'that = that
                                                  }
                               :| []
    , edh'ctx'genr'caller  = Nothing
    , edh'ctx'match        = true
    , edh'ctx'stmt         = mth'body
    , edh'ctx'pure         = False
    , edh'ctx'exporting    = False
    , edh'ctx'eff'defining = False
    }


edhForLoop
  :: EdhThreadState -- ets to prepare the looping
  -> ArgsReceiver
  -> Expr
  -> Expr
  -> (EdhValue -> STM ())
  -> ((EdhTxExit -> EdhTx) -> STM ())
  -> STM ()
edhForLoop !etsLoopPrep !argsRcvr !iterExpr !doExpr !iterCollector !forLooper =
  case deParen iterExpr of
    CallExpr !calleeExpr !argsSndr -> -- loop over a procedure call
      runEdhTx etsLoopPrep $ evalExpr calleeExpr $ \ !calleeVal _ets ->
        case calleeVal of
          EdhBoundProc callee@EdhGnrtor{} !this !that !effOuter ->
            loopCallGenr argsSndr callee this that
              $ flip (maybe id) effOuter
              $ \ !outerScope !s -> s { edh'effects'stack = outerScope }
          EdhProcedure callee@EdhGnrtor{} !effOuter ->
            loopCallGenr argsSndr
                         callee
                         (edh'scope'this scopeLooper)
                         (edh'scope'that scopeLooper)
              $ flip (maybe id) effOuter
              $ \ !outerScope !s -> s { edh'effects'stack = outerScope }

          (EdhObject !obj) -> -- calling an object
            lookupEdhObjAttr obj (AttrByName "__call__") >>= \(!this', !mth) ->
              case mth of
                EdhBoundProc callee@EdhGnrtor{} !this !that !effOuter ->
                  loopCallGenr argsSndr callee this that
                    $ flip (maybe id) effOuter
                    $ \ !outerScope !s -> s { edh'effects'stack = outerScope }
                EdhProcedure callee@EdhGnrtor{} !effOuter ->
                  loopCallGenr argsSndr callee this' obj
                    $ flip (maybe id) effOuter
                    $ \ !outerScope !s -> s { edh'effects'stack = outerScope }
                -- not a callable generator object, assume to loop over
                -- its return value
                _ ->
                  edhPrepareCall etsLoopPrep calleeVal argsSndr $ \ !mkCall ->
                    runEdhTx etsLoopPrep $ mkCall $ \ !iterVal _ets ->
                      loopOverValue iterVal
          -- calling other procedures, assume to loop over its return value
          _ -> edhPrepareCall etsLoopPrep calleeVal argsSndr $ \ !mkCall ->
            runEdhTx etsLoopPrep $ mkCall $ \ !iterVal _ets ->
              loopOverValue iterVal

    _ -> -- loop over an iterable value
         runEdhTx etsLoopPrep $ evalExpr iterExpr $ \ !iterVal _ets ->
      loopOverValue $ edhDeCaseClose iterVal

 where
  scopeLooper = contextScope $ edh'context etsLoopPrep

  loopCallGenr
    :: ArgsPacker
    -> EdhCallable
    -> Object
    -> Object
    -> (Scope -> Scope)
    -> STM ()
  loopCallGenr argsSndr (EdhGnrtor !gnr'proc) !this !that !scopeMod =
    packEdhArgs etsLoopPrep argsSndr $ \ !apk ->
      case edh'procedure'body $ edh'procedure'decl gnr'proc of

        -- calling a host generator
        Right !hp -> forLooper $ \ !exit !ets -> do
          -- a host procedure views the same scope entity as of the caller's
          -- call frame
          let !ctx         = edh'context ets
              !scope       = contextScope ctx
              !calleeScope = (lexicalScopeOf gnr'proc)
                { edh'scope'entity = edh'scope'entity scope
                , edh'scope'this   = this
                , edh'scope'that   = that
                , edh'scope'proc   = gnr'proc
                , edh'scope'caller = edh'ctx'stmt ctx
                }
              !calleeCtx = ctx
                { edh'ctx'stack        = calleeScope <| edh'ctx'stack ctx
                , edh'ctx'genr'caller  = Just (ets, recvYield exit)
                , edh'ctx'match        = true
                , edh'ctx'pure         = False
                , edh'ctx'exporting    = False
                , edh'ctx'eff'defining = False
                }
              !etsCallee = ets { edh'context = calleeCtx }
          runEdhTx etsCallee $ hp apk $ \ !val ->
            edhSwitchState etsLoopPrep $ exit val

        -- calling an Edh generator
        Left !pb -> forLooper $ \ !exit ->
          callEdhMethod' (Just (etsLoopPrep, recvYield exit))
                         this
                         that
                         gnr'proc
                         pb
                         apk
                         scopeMod
              -- return the result in CPS with looper ets restored
            $ \ !gnrRtn -> edhSwitchState etsLoopPrep $ case gnrRtn of
                EdhContinue ->
                  -- todo what's the case a generator would return a continue?
                  exitEdhTx exit nil
                EdhBreak ->
                  -- todo what's the case a generator would return a break?
                  exitEdhTx exit nil
                EdhReturn !rtnVal -> -- it'll be double return, in
                  -- case do block issued return and propagated here
                  -- or the generator can make it that way, which is
                  -- black magic
                  -- unwrap the return, as result of this for-loop 
                  exitEdhTx exit rtnVal
                -- otherwise passthrough
                _ -> exitEdhTx exit gnrRtn

  loopCallGenr _ !callee _ _ _ =
    throwEdhSTM etsLoopPrep EvalError $ "bug: unexpected generator: " <> T.pack
      (show callee)

  -- receive one yielded value from the generator, the 'genrCont' here is
  -- to continue the generator execution, result passed to the 'genrCont'
  -- here is to be the eval'ed value of the `yield` expression from the
  -- generator's perspective, or exception to be thrown from there
  recvYield
    :: EdhTxExit -> EdhValue -> (Either EdhValue EdhValue -> STM ()) -> STM ()
  recvYield !exit !yielded'val !genrCont = do
    let
      doOne !exitOne !etsTry =
        recvEdhArgs
            etsTry
            (edh'context etsTry)
            argsRcvr
            (case yielded'val of
              EdhArgsPack apk -> apk
              _               -> ArgsPack [yielded'val] odEmpty
            )
          $ \ !em -> do
              iopdUpdate (odToList em) (edh'scope'entity scopeLooper)
              runEdhTx etsTry $ evalExpr doExpr exitOne
      doneOne !doResult = case edhDeCaseClose doResult of
        EdhContinue ->
          -- send nil to generator on continue
          genrCont $ Right nil
        EdhBreak ->
          -- break out of the for-from-do loop,
          -- the generator on <break> yielded will return
          -- nil, effectively have the for loop eval to nil
          genrCont $ Right EdhBreak
        EdhCaseOther ->
          -- send nil to generator on no-match of a branch
          genrCont $ Right nil
        EdhFallthrough ->
          -- send nil to generator on fallthrough
          genrCont $ Right nil
        EdhReturn EdhReturn{} -> -- this has special meaning
          -- Edh code should not use this pattern
          throwEdhSTM etsLoopPrep UsageError "double return from do-of-for?"
        EdhReturn !rtnVal ->
          -- early return from for-from-do, the geneerator on
          -- double wrapped return yielded, will unwrap one
          -- level and return the result, effectively have the
          -- for loop eval to return that 
          genrCont $ Right $ EdhReturn $ EdhReturn rtnVal
        !val -> do
          -- vanilla val from do, send to generator
          iterCollector val
          genrCont $ Right val
    case yielded'val of
      EdhNil -> -- nil yielded from a generator effectively early stops
        exitEdhSTM etsLoopPrep exit nil
      EdhContinue ->
        throwEdhSTM etsLoopPrep EvalError "generator yielded continue"
      EdhBreak -> throwEdhSTM etsLoopPrep EvalError "generator yielded break"
      EdhReturn{} ->
        throwEdhSTM etsLoopPrep EvalError "generator yielded return"
      _ -> edhCatchSTM etsLoopPrep doOne doneOne $ \ !exv _recover rethrow ->
        case exv of
          EdhNil -> rethrow -- no exception occurred in do block
          _ -> -- exception uncaught in do block
            -- propagate to the generator, the genr may catch it or 
            -- the exception will propagate to outer of for-from-do
            genrCont $ Left exv

  loopOverValue :: EdhValue -> STM ()
  loopOverValue !iterVal = forLooper $ \ !exit !ets -> do
    let !ctx   = edh'context ets
        !scope = contextScope ctx
        -- do one iteration
        do1 :: ArgsPack -> STM () -> STM ()
        do1 !apk !next = recvEdhArgs ets ctx argsRcvr apk $ \ !em -> do
          iopdUpdate (odToList em) (edh'scope'entity scope)
          runEdhTx ets $ evalExpr doExpr $ \ !doResult -> case doResult of
            EdhBreak ->
              -- break for loop
              exitEdhTx exit nil
            rtn@EdhReturn{} ->
              -- early return during for loop
              exitEdhTx exit rtn
            _ -> \_ets -> do
              -- continue for loop
              iterCollector doResult
              next

        -- loop over a series of args packs
        iterThem :: [ArgsPack] -> STM ()
        iterThem []           = exitEdhSTM ets exit nil
        iterThem (apk : apks) = do1 apk $ iterThem apks

        -- loop over a subscriber's channel of an event sink
        iterEvt :: TChan EdhValue -> STM ()
        iterEvt !subChan = edhDoSTM ets $ readTChan subChan >>= \case
          EdhNil -> -- nil marks end-of-stream from an event sink
            exitEdhSTM ets exit nil -- stop the for-from-do loop
          EdhArgsPack !apk -> do1 apk $ iterEvt subChan
          !v               -> do1 (ArgsPack [v] odEmpty) $ iterEvt subChan

    case edhUltimate iterVal of

      -- loop from an event sink
      (EdhSink !sink) -> subscribeEvents sink >>= \(!subChan, !mrv) ->
        case mrv of
          Nothing  -> iterEvt subChan
          Just !ev -> case ev of
            EdhNil -> -- this sink is already marked at end-of-stream
              exitEdhSTM ets exit nil
            EdhArgsPack !apk -> do1 apk $ iterEvt subChan
            !v               -> do1 (ArgsPack [v] odEmpty) $ iterEvt subChan

      -- loop from a positonal-only args pack
      (EdhArgsPack (ArgsPack !args !kwargs)) | odNull kwargs -> iterThem
        [ case val of
            EdhArgsPack !apk' -> apk'
            _                 -> ArgsPack [val] odEmpty
        | val <- args
        ]

      -- loop from a keyword-only args pack
      (EdhArgsPack (ArgsPack !args !kwargs)) | null args -> iterThem
        [ ArgsPack [attrKeyValue k, v] odEmpty | (k, v) <- odToList kwargs ]

      -- loop from a list
      (EdhList (List _ !l)) -> do
        !ll <- readTVar l
        iterThem
          [ case val of
              EdhArgsPack !apk' -> apk'
              _                 -> ArgsPack [val] odEmpty
          | val <- ll
          ]

      -- loop from a dict
      (EdhDict (Dict _ !d)) -> do
        !del <- iopdToList d
        -- don't be tempted to yield pairs from a dict here,
        -- it'll be messy if some entry values are themselves pairs
        iterThem [ ArgsPack [k, v] odEmpty | (k, v) <- del ]

      -- TODO define the magic method for an object to be able to respond
      --      to for-from-do looping

      _ ->
        throwEdhSTM ets EvalError
          $  "can not do a for loop from "
          <> T.pack (edhTypeNameOf iterVal)
          <> ": "
          <> T.pack (show iterVal)


-- todo this should really be in `CoreLang.hs`, but there has no access to 
--      'throwEdh' without cyclic imports, maybe some day we shall try
--      `.hs-boot` files
-- | resolve an attribute addressor, either alphanumeric named or symbolic
resolveEdhAttrAddr
  :: EdhThreadState -> AttrAddressor -> (AttrKey -> STM ()) -> STM ()
resolveEdhAttrAddr _ (NamedAttr !attrName) !exit = exit (AttrByName attrName)
resolveEdhAttrAddr !ets (SymbolicAttr !symName) !exit =
  let scope = contextScope $ edh'context ets
  in  resolveEdhCtxAttr scope (AttrByName symName) >>= \case
        Just (!val, _) -> case val of
          (EdhSymbol !symVal ) -> exit (AttrBySym symVal)
          (EdhString !nameVal) -> exit (AttrByName nameVal)
          _ ->
            throwEdhSTM ets EvalError
              $  "not a symbol/string as "
              <> symName
              <> ", it is a "
              <> T.pack (edhTypeNameOf val)
              <> ": "
              <> T.pack (show val)
        Nothing ->
          throwEdhSTM ets EvalError
            $  "no symbol/string named "
            <> T.pack (show symName)
            <> " available"
{-# INLINE resolveEdhAttrAddr #-}


-- | Throw a tagged error from Edh computation
--
-- a bit similar to `return` in Haskell, this doesn't cease the execution
-- of subsequent actions following it, be cautious.
throwEdhTx :: EdhErrorTag -> Text -> EdhTx
throwEdhTx !et !msg !ets = throwEdhSTM ets et msg
-- | Throw a tagged error from STM monad running Edh computation
--
-- a bit similar to `return` in Haskell, this doesn't cease the execution
-- of subsequent actions following it, be cautious.
throwEdhSTM :: EdhThreadState -> EdhErrorTag -> Text -> STM ()
throwEdhSTM !ets !tag !msg = edhWrapException (toException edhErr)
  >>= \ !exo -> edhThrowSTM ets $ EdhObject exo
 where
  !edhWrapException = edh'exception'wrapper (edh'ctx'world $ edh'context ets)
  !cc               = getEdhCallContext 0 ets
  !edhErr           = EdhError tag msg cc


edhThrowTx :: EdhValue -> EdhTx
edhThrowTx = flip edhThrowSTM
-- | Throw arbitrary value from Edh
--
-- a bit similar to `return` in Haskell, this doesn't cease the execution
-- of subsequent actions following it, be cautious.
edhThrowSTM :: EdhThreadState -> EdhValue -> STM ()
edhThrowSTM !ets !exv = do
  let propagateExc :: EdhValue -> [Scope] -> STM ()
      propagateExc exv' [] = edhErrorUncaught ets exv'
      propagateExc exv' (frame : stack) =
        edh'excpt'hndlr frame exv' $ \exv'' -> propagateExc exv'' stack
  propagateExc exv $ NE.toList $ edh'ctx'stack $ edh'context ets

edhErrorUncaught :: EdhThreadState -> EdhValue -> STM ()
edhErrorUncaught !ets !exv = case exv of
  EdhObject exo -> case edh'obj'store exo of
    HostStore !hsv -> fromDynamic <$> readTVar hsv >>= \case
      -- TODO replace cc in err if is empty here ?
      Just (exc :: SomeException) -> throwSTM exc
      -- TODO support magic method to coerce object as exception ?
      Nothing                     -> edhValueRepr ets exv
        $ \msg -> throwSTM $ EdhError EvalError msg $ getEdhCallContext 0 ets
    -- TODO support magic method to coerce object as exception ?
    _ -> edhValueRepr ets exv
      $ \msg -> throwSTM $ EdhError EvalError msg $ getEdhCallContext 0 ets
  EdhString !msg -> throwSTM $ EdhError EvalError msg $ getEdhCallContext 0 ets
  -- coerce arbitrary value to EdhError
  _              -> edhValueRepr ets exv
    $ \msg -> throwSTM $ EdhError EvalError msg $ getEdhCallContext 0 ets


-- | Catch possible throw from the specified try action
edhCatchTx
  :: (EdhTxExit -> EdhTx)     -- ^ tryAct
  -> EdhTxExit                -- ^ normal/recovered exit
  -> (  EdhTxExit             -- ^ recover exit
     -> EdhTx                 -- ^ rethrow exit
     -> EdhTx
     ) -- edh'ctx'match of this Edh tx being the thrown value or nil
  -> EdhTx
edhCatchTx !tryAct !exit !passOn !etsOuter =
  edhCatchSTM etsOuter tryAct (runEdhTx etsOuter . exit)
    $ \ !exv recover rethrow -> do
        let !ctxOuter = edh'context etsOuter
            !ctxHndl  = ctxOuter { edh'ctx'match = exv }
            !etsHndl  = etsOuter { edh'context = ctxHndl }
        runEdhTx etsHndl $ passOn (const . recover) (const rethrow)
-- | Catch possible throw from the specified try action
edhCatchSTM
  :: EdhThreadState
  -> (EdhTxExit -> EdhTx)     -- ^ tryAct
  -> (EdhValue -> STM ())     -- ^ normal/recovered exit
  -> (  EdhValue              -- ^ thrown value or nil
     -> (EdhValue -> STM ())  -- ^ recover exit
     -> STM ()                -- ^ rethrow exit
     -> STM ()
     )
  -> STM ()
edhCatchSTM !etsOuter !tryAct !exit !passOn = do
  hndlrTh <- unsafeIOToSTM myThreadId
  let
    !ctxOuter   = edh'context etsOuter
    !scopeOuter = contextScope ctxOuter
    !tryScope   = scopeOuter { edh'excpt'hndlr = hndlr }
    !tryCtx =
      ctxOuter { edh'ctx'stack = tryScope :| NE.tail (edh'ctx'stack ctxOuter) }
    !etsTry = etsOuter { edh'context = tryCtx }
    hndlr :: EdhExcptHndlr
    hndlr !exv !rethrow = do
      let goRecover :: EdhValue -> STM ()
          -- an exception handler provided another result value to recover
          goRecover !result = isProgramHalt exv >>= \case
            True  -> goRethrow -- never recover from ProgramHalt
            False -> do
              -- do recover from the exception
              rcvrTh <- unsafeIOToSTM myThreadId
              if rcvrTh /= hndlrTh
                then -- just skip the action if from a different thread
                     return () -- other than the handler installer
                else exit result
          goRethrow :: STM ()
          goRethrow = edh'excpt'hndlr scopeOuter exv rethrow
      passOn exv goRecover goRethrow
  runEdhTx etsTry $ tryAct $ \ !tryResult _ets -> do
    -- no exception occurred, go trigger finally block
    rcvrTh <- unsafeIOToSTM myThreadId
    if rcvrTh /= hndlrTh
      then -- just skip the action if from a different thread
           return () -- other than the handler installer
      else passOn nil (error "bug: recovering from finally block")
        $ exit tryResult
 where
  isProgramHalt !exv = case exv of
    EdhObject !exo -> case edh'obj'store exo of
      HostStore !hsv -> fromDynamic <$> readTVar hsv >>= \case
        Just ProgramHalt{} -> return True
        _                  -> return False
      _ -> return False
    _ -> return False


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
  where !wops = edh'world'operators world


evalEdh :: String -> Text -> EdhTxExit -> EdhTx
evalEdh !srcName = evalEdh' srcName 1
evalEdh' :: String -> Int -> Text -> EdhTxExit -> EdhTx
evalEdh' !srcName !lineNo !srcCode !exit !ets = do
  let ctx   = edh'context ets
      world = edh'ctx'world ctx
  parseEdh' world srcName lineNo srcCode >>= \case
    Left !err -> do
      let !msg = T.pack $ errorBundlePretty err
          !edhWrapException =
            edh'exception'wrapper (edh'ctx'world $ edh'context ets)
          !cc     = getEdhCallContext 0 ets
          !edhErr = EdhError ParseError msg cc
      edhWrapException (toException edhErr)
        >>= \ !exo -> edhThrowSTM ets (EdhObject exo)
    Right !stmts -> runEdhTx ets $ evalBlock stmts exit


deParen :: Expr -> Expr
deParen x = case x of
  ParenExpr x' -> deParen x'
  _            -> x

deApk :: ArgsPack -> ArgsPack
deApk (ArgsPack [EdhArgsPack !apk] !kwargs) | odNull kwargs = deApk apk
deApk apk = apk

evalStmt :: StmtSrc -> EdhTxExit -> EdhTx
evalStmt ss@(StmtSrc (_sp, !stmt)) !exit !ets =
  runEdhTx ets { edh'context = (edh'context ets) { edh'ctx'stmt = ss } }
    $ evalStmt' stmt
    $ \ !rtn -> edhSwitchState ets $ exit rtn

evalCaseBlock :: Expr -> EdhTxExit -> EdhTx
evalCaseBlock !expr !exit = case expr of
  -- case-of with a block is normal
  BlockExpr stmts' -> evalBlock stmts' exit
  -- single branch case is some special
  _                -> evalExpr expr $ \ !val -> case val of
    -- the only branch did match
    (EdhCaseClose !v) -> exitEdhTx exit $ edhDeCaseClose v
    -- the only branch didn't match
    EdhCaseOther      -> exitEdhTx exit nil
    -- yield should have been handled by 'evalExpr'
    (EdhYield _)      -> throwEdhTx EvalError "bug yield reached block"
    -- ctrl to be propagated outwards, as this is the only stmt, no need to
    -- be specifically written out
    -- EdhFallthrough    -> exitEdhTx exit EdhFallthrough
    -- EdhBreak          -> exitEdhTx exit EdhBreak
    -- EdhContinue       -> exitEdhTx exit EdhContinue
    -- (EdhReturn !v)    -> exitEdhTx exit (EdhReturn v)
    -- other vanilla result, propagate as is
    _                 -> exitEdhTx exit val

evalBlock :: [StmtSrc] -> EdhTxExit -> EdhTx
evalBlock []    !exit = exitEdhTx exit nil
evalBlock [!ss] !exit = evalStmt ss $ \ !val -> case val of
  -- last branch did match
  (EdhCaseClose !v) -> exitEdhTx exit $ edhDeCaseClose v
  -- yield should have been handled by 'evalExpr'
  (EdhYield     _ ) -> throwEdhTx EvalError "bug: yield reached block"
  -- ctrl to be propagated outwards, as this is the last stmt, no need to
  -- be specifically written out
  -- EdhCaseOther      -> exitEdhTx exit EdhCaseOther
  -- EdhFallthrough    -> exitEdhTx exit EdhFallthrough
  -- EdhRethrow        -> exitEdhTx exit EdhRethrow
  -- EdhBreak          -> exitEdhTx exit EdhBreak
  -- EdhContinue       -> exitEdhTx exit EdhContinue
  -- (EdhReturn !v)    -> exitEdhTx exit (EdhReturn v)
  -- other vanilla result, propagate as is
  _                 -> exitEdhTx exit val
evalBlock (ss : rest) !exit = evalStmt ss $ \ !val -> case val of
    -- a branch matched, finish this block
  (EdhCaseClose !v) -> exitEdhTx exit $ edhDeCaseClose v
  -- should continue to next branch (or stmt)
  EdhCaseOther      -> evalBlock rest exit
  -- should fallthrough to next branch (or stmt)
  EdhFallthrough    -> evalBlock rest exit
  -- yield should have been handled by 'evalExpr'
  (EdhYield _)      -> throwEdhTx EvalError "bug: yield reached block"
  -- ctrl to interrupt this block, and to be propagated outwards
  EdhRethrow        -> exitEdhTx exit EdhRethrow
  EdhBreak          -> exitEdhTx exit EdhBreak
  EdhContinue       -> exitEdhTx exit EdhContinue
  (EdhReturn !v)    -> exitEdhTx exit (EdhReturn v)
  -- other vanilla result, continue this block
  _                 -> evalBlock rest exit


-- | a left-to-right expr list eval'er, returning a tuple
evalExprs :: [Expr] -> EdhTxExit -> EdhTx
-- here 'EdhArgsPack' is used as an intermediate container,
-- no apk intended to be returned anyway
evalExprs []       !exit = exitEdhTx exit (EdhArgsPack $ ArgsPack [] odEmpty)
evalExprs (x : xs) !exit = evalExpr x $ \ !val -> evalExprs xs $ \ !tv ->
  case tv of
    EdhArgsPack (ArgsPack !l _) ->
      exitEdhTx exit (EdhArgsPack $ ArgsPack (edhDeCaseClose val : l) odEmpty)
    _ -> error "bug"


evalStmt' :: Stmt -> EdhTxExit -> EdhTx
evalStmt' !stmt !exit = case stmt of

  ExprStmt !expr -> evalExpr expr $ \result -> exitEdhTx exit result

  LetStmt !argsRcvr !argsSndr -> \ !ets -> do
    let !ctx    = edh'context ets
        !scope  = contextScope ctx
        -- ensure args sending and receiving happens within a same tx
        -- for atomicity of the let statement
        !etsLet = ets { edh'in'tx = True }
    packEdhArgs etsLet argsSndr $ \ !apk ->
      recvEdhArgs etsLet ctx argsRcvr (deApk apk) $ \ !um -> do
        if not (edh'ctx'eff'defining ctx)
          then -- normal multi-assignment
               iopdUpdate (odToList um) (edh'scope'entity scope)
          else do -- define effectful artifacts by multi-assignment
            let !effd = [ (attrKeyValue k, v) | (k, v) <- odToList um ]
            iopdLookup (AttrByName edhEffectsMagicName) (edh'scope'entity scope)
              >>= \case
                    Just (EdhDict (Dict _ !effDS)) -> iopdUpdate effd effDS
                    _                              -> do
                      !d <- EdhDict <$> createEdhDict effd
                      iopdInsert (AttrByName edhEffectsMagicName)
                                 d
                                 (edh'scope'entity scope)
        let !maybeExp2ent = if edh'ctx'exporting ctx
              then Nothing -- not exporting
              -- always export to current this object's scope, and possibly a
              -- class object. a method procedure's scope has no way to be
              -- imported from, only objects (most are module objects) can be
              -- an import source.
              else case edh'obj'store $ edh'scope'this scope of
                HashStore  !hs             -> Just hs
                ClassStore (Class _ !cs _) -> Just cs
                _                          -> Nothing
        case maybeExp2ent of
          Nothing       -> pure ()
          Just !exp2Ent -> do -- do export what's assigned
            let !impd = [ (attrKeyValue k, v) | (k, v) <- odToList um ]
            iopdLookup (AttrByName edhExportsMagicName) exp2Ent >>= \case
              Just (EdhDict (Dict _ !exp2ds)) -> iopdUpdate impd exp2ds
              _                               -> do -- todo warn if of wrong type
                !d <- EdhDict <$> createEdhDict impd
                iopdInsert (AttrByName edhExportsMagicName) d exp2Ent
        exitEdhSTM ets exit nil
        -- let statement evaluates to nil always, with previous thread state

  BreakStmt        -> exitEdhTx exit EdhBreak
  ContinueStmt     -> exitEdhTx exit EdhContinue
  FallthroughStmt  -> exitEdhTx exit EdhFallthrough
  RethrowStmt      -> exitEdhTx exit EdhRethrow

  ReturnStmt !expr -> evalExpr expr $ \ !v2r -> case edhDeCaseClose v2r of
    val@EdhReturn{} -> exitEdhTx exit (EdhReturn val)
      -- actually when a generator procedure checks the result of its `yield`
      -- for the case of early return from the do block, if it wants to
      -- cooperate, double return is the only option
      -- throwEdhTx UsageError "you don't double return"
    !val            -> exitEdhTx exit (EdhReturn val)


  AtoIsoStmt !expr -> \ !ets ->
    runEdhTx ets { edh'in'tx = True } -- ensure in'tx state
      $ evalExpr expr
        -- restore original tx state
      $ \ !val -> edhSwitchState ets $ exit $ edhDeCaseClose val


  GoStmt !expr -> case expr of

    CaseExpr !tgtExpr !branchesExpr -> evalExpr tgtExpr $ \ !val !etsForker ->
      runEdhTx etsForker
        $ forkEdh
            (\ !etsForkee -> etsForkee
              { edh'context = (edh'context etsForkee) { edh'ctx'match = edhDeCaseClose
                                                        val
                                                      }
              }
            )
        $ evalCaseBlock branchesExpr endOfEdh

    (CallExpr !calleeExpr !argsSndr) ->
      evalExpr calleeExpr $ \ !calleeVal !etsForker ->
        edhPrepareCall etsForker calleeVal argsSndr
          $ \ !mkCall -> runEdhTx etsForker $ forkEdh id (mkCall endOfEdh)

    (ForExpr !argsRcvr !iterExpr !doExpr) -> \ !etsForker ->
      edhForLoop etsForker argsRcvr iterExpr doExpr (const $ return ())
        $ \ !runLoop -> runEdhTx etsForker $ forkEdh id (runLoop endOfEdh)

    _ -> forkEdh id $ evalExpr expr endOfEdh


  DeferStmt !expr -> do
    let schedDefered
          :: EdhThreadState
          -> (EdhThreadState -> EdhThreadState)
          -> EdhTx
          -> STM ()
        schedDefered !etsSched !bootMod !etx = do
          modifyTVar' (edh'defers etsSched)
                      ((DeferRecord etsSched $ etx . bootMod) :)
          runEdhTx etsSched $ exit nil

    case expr of

      CaseExpr !tgtExpr !branchesExpr ->
        evalExpr tgtExpr $ \ !val !etsSched ->
          schedDefered
              etsSched
              (\ !etsDefer -> etsDefer
                { edh'context = (edh'context etsDefer)
                  { edh'ctx'match = edhDeCaseClose val
                  }
                }
              )
            $ evalCaseBlock branchesExpr endOfEdh

      (CallExpr !calleeExpr !argsSndr) ->
        evalExpr calleeExpr $ \ !calleeVal !etsSched ->
          edhPrepareCall etsSched calleeVal argsSndr
            $ \ !mkCall -> schedDefered etsSched id (mkCall endOfEdh)

      (ForExpr !argsRcvr !iterExpr !doExpr) -> \ !etsSched ->
        edhForLoop etsSched argsRcvr iterExpr doExpr (const $ return ())
          $ \ !runLoop -> schedDefered etsSched id (runLoop endOfEdh)

      _ -> \ !etsSched -> schedDefered etsSched id $ evalExpr expr endOfEdh


  PerceiveStmt !sinkExpr !bodyExpr -> evalExpr sinkExpr $ \ !sinkVal !ets ->
    case edhUltimate sinkVal of
      EdhSink !sink -> do
        let reactor !breakThread =
              evalExpr bodyExpr $ \ !reactResult _etsReactor ->
                case reactResult of
                  EdhBreak -> writeTVar breakThread True
                  -- todo warn or even err out in case return/continue/default
                  --      etc. are returned to here?
                  _        -> return ()
        (perceiverChan, _) <- subscribeEvents sink
        modifyTVar' (edh'perceivers ets)
                    (PerceiveRecord perceiverChan ets reactor :)
        exitEdhSTM ets exit nil
      _ ->
        throwEdhSTM ets EvalError
          $  "can only perceive from an event sink, not a "
          <> T.pack (edhTypeNameOf sinkVal)
          <> ": "
          <> T.pack (show sinkVal)


  ThrowStmt excExpr ->
    evalExpr excExpr $ \ !exv -> edhThrowTx $ edhDeCaseClose exv


  WhileStmt !cndExpr !bodyStmt -> do
    let doWhile :: EdhTx
        doWhile = evalExpr cndExpr $ \ !cndVal -> case edhDeCaseClose cndVal of
          EdhBool True -> evalStmt bodyStmt $ \ !blkVal ->
            case edhDeCaseClose blkVal of
              -- early stop of procedure
              rtnVal@EdhReturn{} -> exitEdhTx exit rtnVal
              -- break while loop
              EdhBreak           -> exitEdhTx exit nil
              -- continue while loop
              _                  -> doWhile
          EdhBool False -> exitEdhTx exit nil
          EdhNil        -> exitEdhTx exit nil
          _ ->
            throwEdhTx EvalError
              $  "invalid condition value for while: "
              <> T.pack (edhTypeNameOf cndVal)
              <> ": "
              <> T.pack (show cndVal)
    doWhile


  ExtendsStmt !superExpr -> evalExpr superExpr $ \ !superVal !ets ->
    case edhDeCaseClose superVal of
      EdhObject !superObj ->
        let
          !magicSpell = AttrByName "<-^"

          !ctx        = edh'context ets
          !this       = edh'scope'this $ contextScope ctx

          noMetaMagic :: EdhTx
          noMetaMagic _ets = lookupEdhSelfAttr superObj magicSpell >>= \case
            EdhNil    -> exitEdhSTM ets exit nil
            !magicMth -> runEdhTx ets $ withMagicMethod magicMth
          callMagicMethod !mthThis !mthThat !mth = case objectScope this of
            Nothing ->
              runEdhTx ets
                $ callEdhMethod mthThis
                                mthThat
                                mth
                                (ArgsPack [edhNone] odEmpty)
                                id
                $ \_magicRtn _ets -> exitEdhSTM ets exit nil
            Just !objScope -> do
              !scopeObj <- mkScopeWrapper ctx objScope
              runEdhTx ets
                $ callEdhMethod mthThis
                                mthThat
                                mth
                                (ArgsPack [EdhObject scopeObj] odEmpty)
                                id
                $ \_magicRtn _ets -> exitEdhSTM ets exit nil
          withMagicMethod :: EdhValue -> EdhTx
          withMagicMethod !magicMth _ets = case magicMth of
            EdhNil -> exitEdhSTM ets exit nil
            EdhProcedure (EdhMethod !mth) _ ->
              callMagicMethod superObj this mth
            -- even if it's already bound, should use `this` here as
            -- contextual `that` there
            EdhBoundProc (EdhMethod !mth) !mthThis _mthThat _ ->
              callMagicMethod mthThis this mth
            _ ->
              throwEdhSTM ets EvalError
                $  "invalid magic (<-^) method type: "
                <> T.pack (edhTypeNameOf magicMth)

          doExtends = do
            modifyTVar' (edh'obj'supers this) (++ [superObj])
            runEdhTx ets $ getObjAttrWSM edhMetaMagicSpell
                                         superObj
                                         magicSpell
                                         noMetaMagic
                                         withMagicMethod
        in
          case edh'obj'store this of
            ClassStore{} -> case edh'obj'store superObj of
              ClassStore{} -> doExtends
              _ -> throwEdhSTM ets
                               UsageError
                               "can not extend a non-class by a class object"
            _ -> doExtends
      _ ->
        throwEdhSTM ets UsageError
          $  "can only extends an object, not a "
          <> T.pack (edhTypeNameOf superVal)
          <> ": "
          <> T.pack (show superVal)


  EffectStmt !effs -> \ !ets ->
    runEdhTx ets
        { edh'context = (edh'context ets) { edh'ctx'eff'defining = True }
        }
      $ evalExpr effs
      $ \ !rtn -> edhSwitchState ets $ exit rtn


  VoidStmt -> exitEdhTx exit nil


importInto :: EntityStore -> ArgsReceiver -> Expr -> EdhTxExit -> EdhTx
importInto !tgtEnt !argsRcvr !srcExpr !exit = case srcExpr of
  LitExpr (StringLiteral !importSpec) ->
    -- import from specified path
    importEdhModule' tgtEnt argsRcvr importSpec exit
  _ -> evalExpr srcExpr $ \ !srcVal -> case edhDeCaseClose srcVal of
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
      throwEdhTx EvalError
        $  "don't know how to import from a "
        <> T.pack (edhTypeNameOf srcVal)
        <> ": "
        <> T.pack (show srcVal)


edhExportsMagicName :: Text
edhExportsMagicName = "__exports__"

importFromApk :: EntityStore -> ArgsReceiver -> ArgsPack -> EdhTxExit -> EdhTx
importFromApk !tgtEnt !argsRcvr !fromApk !exit !ets =
  recvEdhArgs ets ctx argsRcvr fromApk $ \ !em -> do
    if not (edh'ctx'eff'defining ctx)
      then -- normal import
           iopdUpdate (odToList em) tgtEnt
      else do -- importing effects
        let !effd = [ (attrKeyValue k, v) | (k, v) <- odToList em ]
        iopdLookup (AttrByName edhEffectsMagicName) tgtEnt >>= \case
          Just (EdhDict (Dict _ !dsEff)) -> iopdUpdate effd dsEff
          _                              -> do -- todo warn if of wrong type
            d <- EdhDict <$> createEdhDict effd
            iopdInsert (AttrByName edhEffectsMagicName) d tgtEnt
    when (edh'ctx'exporting ctx) $ do -- do export what's imported
      let !impd = [ (attrKeyValue k, v) | (k, v) <- odToList em ]
      iopdLookup (AttrByName edhExportsMagicName) tgtEnt >>= \case
        Just (EdhDict (Dict _ !dsExp)) -> iopdUpdate impd dsExp
        _                              -> do -- todo warn if of wrong type
          d <- EdhDict <$> createEdhDict impd
          iopdInsert (AttrByName edhExportsMagicName) d tgtEnt
    exitEdhSTM ets exit $ EdhArgsPack fromApk
  where !ctx = edh'context ets

importFromObject :: EntityStore -> ArgsReceiver -> Object -> EdhTxExit -> EdhTx
importFromObject !tgtEnt !argsRcvr !fromObj !exit !ets =
  case edh'obj'store fromObj of
    HashStore  !hs             -> doImp hs
    ClassStore (Class _ !cs _) -> doImp cs
    _ ->
      throwEdhSTM ets UsageError
        $  "can not import from a host object of class "
        <> objClassName fromObj
 where
  doImp :: EntityStore -> STM ()
  doImp !esFrom = iopdLookup (AttrByName edhExportsMagicName) esFrom >>= \case
    Nothing                            -> withExps [] -- nothing exported at all
    Just (EdhDict (Dict _ !dsExpFrom)) -> iopdToList dsExpFrom >>= \ !expl ->
      withExps $ catMaybes
        [ case k of
            EdhString !expKey -> Just (AttrByName expKey, v)
            EdhSymbol !expSym -> Just (AttrBySym expSym, v)
            _                 -> Nothing -- todo warn about this
        | (k, v) <- expl
        ]
    Just !badExplVal ->
      throwEdhSTM ets UsageError $ "bad __exports__ type: " <> T.pack
        (edhTypeNameOf badExplVal)

  withExps :: [(AttrKey, EdhValue)] -> STM ()
  withExps !exps =
    runEdhTx ets
      $ importFromApk tgtEnt argsRcvr (ArgsPack [] $ odFromList exps)
      $ \_ -> exitEdhTx exit $ EdhObject fromObj

importEdhModule' :: EntityStore -> ArgsReceiver -> Text -> EdhTxExit -> EdhTx
importEdhModule' !tgtEnt !argsRcvr !importSpec !exit =
  importEdhModule importSpec $ \ !moduVal -> case moduVal of
    EdhObject !modu -> importFromObject tgtEnt argsRcvr modu exit
    _               -> error "bug: imported module not an object"

importEdhModule :: Text -> EdhTxExit -> EdhTx
importEdhModule !impSpec !exit !ets = if edh'in'tx ets
  then throwEdhSTM ets UsageError "you don't import from within a transaction"
  else do
    moduMap <- readTMVar worldModules
    case Map.lookup normalizedSpec moduMap of
      -- attempt the import specification as direct module id first
      Just !moduSlot -> readTMVar moduSlot >>= \case
        -- import error has been encountered, propagate the error
        EdhNamedValue _ !importError -> edhThrowSTM ets importError
        -- module already imported, got it as is
        !modu                        -> exitEdhSTM ets exit modu
      -- resolving to `.edh` source files from local filesystem
      Nothing -> importFromFS
 where
  !ctx           = edh'context ets
  !worldModules  = edh'world'modules $ edh'ctx'world ctx
  !scope         = contextScope ctx

  normalizedSpec = normalizeImpSpec impSpec
  normalizeImpSpec :: Text -> Text
  normalizeImpSpec = withoutLeadingSlash . withoutTrailingSlash
  withoutLeadingSlash spec = fromMaybe spec $ T.stripPrefix "/" spec
  withoutTrailingSlash spec = fromMaybe spec $ T.stripSuffix "/" spec

  locateModuInFS :: ((FilePath, FilePath) -> STM ()) -> STM ()
  locateModuInFS !exit' =
    lookupEdhCtxAttr scope (AttrByName "__path__") >>= \case
      EdhString !fromPath ->
        lookupEdhCtxAttr scope (AttrByName "__file__") >>= \case
          EdhString !fromFile -> do
            let !nomSpec = case normalizedSpec of
    -- special case for `import * '.'`, 2 possible use cases:
    --
    --  *) from an entry module (i.e. __main__.edh), to import artifacts
    --     from its respective persistent module
    --
    --  *) from a persistent module, to re-populate the module scope with
    --     its own exports (i.e. the dict __exports__ in its scope), in
    --     case the module scope possibly altered after initialization
                  "." -> T.unpack fromPath
                  _   -> T.unpack normalizedSpec
            (nomPath, moduFile) <- unsafeIOToSTM
              $ locateEdhModule (edhPkgPathFrom $ T.unpack fromFile) nomSpec
            exit' (nomPath, moduFile)
          _ -> error "bug: no valid `__file__` in context"
      _ -> error "bug: no valid `__path__` in context"

  importFromFS :: STM ()
  importFromFS =
    flip
        catchSTM
        (\(e :: EdhError) -> case e of
          EdhError !et !msg _ -> throwEdhSTM ets et msg
          _                   -> throwSTM e
        )
      $ locateModuInFS
      $ \(nomPath, moduFile) -> do
          let !moduId = T.pack nomPath
          moduMap' <- takeTMVar worldModules
          case Map.lookup moduId moduMap' of
            Just !moduSlot -> do
              -- put back immediately
              putTMVar worldModules moduMap'
              -- blocking wait the target module loaded
              runEdhTx ets $ edhContSTM $ readTMVar moduSlot >>= \case
                -- TODO GHC should be able to detect cyclic imports as 
                --      deadlock, better to report that more friendly,
                --      and more importantly, to prevent the crash.
                EdhNamedValue _ !importError ->
                  -- the first importer failed loading it,
                  -- replicate the error in this thread
                  edhThrowSTM ets importError
                !modu -> exitEdhSTM ets exit modu
            Nothing -> do -- we are the first importer
              -- allocate an empty slot
              moduSlot <- newEmptyTMVar
              -- put it for global visibility
              putTMVar worldModules $ Map.insert moduId moduSlot moduMap'
              -- try load the module
              edhCatchSTM ets
                          (loadModule moduSlot moduId moduFile)
                          (exitEdhSTM ets exit)
                $ \ !exv _recover !rethrow -> case exv of
                    EdhNil -> rethrow -- no error occurred
                    _      -> do
                      void $ tryPutTMVar moduSlot $ EdhNamedValue
                        "<import-error>"
                        exv
                      -- cleanup on loading error
                      moduMap'' <- takeTMVar worldModules
                      case Map.lookup moduId moduMap'' of
                        Nothing        -> putTMVar worldModules moduMap''
                        Just moduSlot' -> if moduSlot' == moduSlot
                          then putTMVar worldModules
                            $ Map.delete moduId moduMap''
                          else putTMVar worldModules moduMap''
                      rethrow


loadModule :: TMVar EdhValue -> ModuleId -> FilePath -> EdhTxExit -> EdhTx
loadModule !moduSlot !moduId !moduFile !exit !ets = if edh'in'tx ets
  then throwEdhSTM ets
                   UsageError
                   "you don't load a module from within a transaction"
  else
    (unsafeIOToSTM $ streamDecodeUtf8With lenientDecode <$> B.readFile moduFile)
      >>= \case
            Some !moduSource _ _ -> do
              !modu <- edhCreateModule moduId moduFile
              case objectScope modu of
                Nothing -> error "bug: module object has no scope"
                Just !scopeLoad ->
                  let !ctxLoad = ctx
                        { edh'ctx'stack        = scopeLoad <| edh'ctx'stack ctx
                        , edh'ctx'pure         = False
                        , edh'ctx'exporting    = False
                        , edh'ctx'eff'defining = False
                        }
                      !etsLoad = ets { edh'context = ctxLoad }
                  in  runEdhTx etsLoad
                        $ evalEdh moduFile moduSource
                        $ \_moduResult _ets -> do
                            -- arm the successfully loaded module
                            void $ tryPutTMVar moduSlot $ EdhObject modu
                            -- switch back to module importer's scope and continue
                            exitEdhSTM ets exit $ EdhObject modu
 where
  !ctx            = edh'context ets
  !world          = edh'ctx'world ctx

  edhCreateModule = edh'module'creator world


moduleContext :: EdhWorld -> Object -> Context
moduleContext !world !modu = case objectScope modu of
  Nothing         -> error "bug: module object has no scope"
  Just !moduScope -> worldCtx
    { edh'ctx'stack        = moduScope <| edh'ctx'stack worldCtx
    , edh'ctx'exporting    = False
    , edh'ctx'eff'defining = False
    }
  where !worldCtx = worldContext world


intplExpr :: EdhThreadState -> Expr -> (Expr -> STM ()) -> STM ()
intplExpr !ets !x !exit = case x of
  IntplExpr !x' ->
    runEdhTx ets $ evalExpr x' $ \ !val _ets -> exit $ IntplSubs val
  PrefixExpr !pref !x' -> intplExpr ets x' $ \x'' -> exit $ PrefixExpr pref x''
  IfExpr !cond !cons !alt -> intplExpr ets cond $ \cond' ->
    intplExpr ets cons $ \cons' -> case alt of
      Nothing -> exit $ IfExpr cond' cons' Nothing
      Just !altx ->
        intplExpr ets altx $ \altx' -> exit $ IfExpr cond' cons' $ Just altx'
  CaseExpr !tgt !branches -> intplExpr ets tgt $ \tgt' ->
    intplExpr ets branches $ \branches' -> exit $ CaseExpr tgt' branches'
  DictExpr !entries -> seqcontSTM (intplDictEntry ets <$> entries)
    $ \entries' -> exit $ DictExpr entries'
  ListExpr !es ->
    seqcontSTM (intplExpr ets <$> es) $ \es' -> exit $ ListExpr es'
  ArgsPackExpr !argSenders -> seqcontSTM (intplArgSender ets <$> argSenders)
    $ \argSenders' -> exit $ ArgsPackExpr argSenders'
  ParenExpr !x' -> intplExpr ets x' $ \x'' -> exit $ ParenExpr x''
  BlockExpr !ss ->
    seqcontSTM (intplStmtSrc ets <$> ss) $ \ss' -> exit $ BlockExpr ss'
  YieldExpr !x'             -> intplExpr ets x' $ \x'' -> exit $ YieldExpr x''
  ForExpr !rcvs !fromX !doX -> intplExpr ets fromX
    $ \fromX' -> intplExpr ets doX $ \doX' -> exit $ ForExpr rcvs fromX' doX'
  AttrExpr !addr -> intplAttrAddr ets addr $ \addr' -> exit $ AttrExpr addr'
  IndexExpr !v !t ->
    intplExpr ets v $ \v' -> intplExpr ets t $ \t' -> exit $ IndexExpr v' t'
  CallExpr !v !args -> intplExpr ets v $ \v' ->
    seqcontSTM (intplArgSndr ets <$> args) $ \args' -> exit $ CallExpr v' args'
  InfixExpr !op !lhe !rhe -> intplExpr ets lhe
    $ \lhe' -> intplExpr ets rhe $ \rhe' -> exit $ InfixExpr op lhe' rhe'
  ImportExpr !rcvrs !xFrom !maybeInto -> intplArgsRcvr ets rcvrs $ \rcvrs' ->
    intplExpr ets xFrom $ \xFrom' -> case maybeInto of
      Nothing     -> exit $ ImportExpr rcvrs' xFrom' Nothing
      Just !oInto -> intplExpr ets oInto
        $ \oInto' -> exit $ ImportExpr rcvrs' xFrom' $ Just oInto'
  _ -> exit x

intplDictEntry
  :: EdhThreadState
  -> (DictKeyExpr, Expr)
  -> ((DictKeyExpr, Expr) -> STM ())
  -> STM ()
intplDictEntry !ets (k@LitDictKey{}, !x) !exit =
  intplExpr ets x $ \x' -> exit (k, x')
intplDictEntry !ets (AddrDictKey !k, !x) !exit = intplAttrAddr ets k
  $ \k' -> intplExpr ets x $ \x' -> exit (AddrDictKey k', x')
intplDictEntry !ets (ExprDictKey !k, !x) !exit =
  intplExpr ets k $ \k' -> intplExpr ets x $ \x' -> exit (ExprDictKey k', x')

intplArgSender :: EdhThreadState -> ArgSender -> (ArgSender -> STM ()) -> STM ()
intplArgSender !ets (UnpackPosArgs !x) !exit =
  intplExpr ets x $ \x' -> exit $ UnpackPosArgs x'
intplArgSender !ets (UnpackKwArgs !x) !exit =
  intplExpr ets x $ \x' -> exit $ UnpackKwArgs x'
intplArgSender !ets (UnpackPkArgs !x) !exit =
  intplExpr ets x $ \x' -> exit $ UnpackPkArgs x'
intplArgSender !ets (SendPosArg !x) !exit =
  intplExpr ets x $ \x' -> exit $ SendPosArg x'
intplArgSender !ets (SendKwArg !addr !x) !exit =
  intplExpr ets x $ \x' -> exit $ SendKwArg addr x'

intplAttrAddr :: EdhThreadState -> AttrAddr -> (AttrAddr -> STM ()) -> STM ()
intplAttrAddr !ets !addr !exit = case addr of
  IndirectRef !x' !a -> intplExpr ets x' $ \x'' -> exit $ IndirectRef x'' a
  _                  -> exit addr

intplArgsRcvr
  :: EdhThreadState -> ArgsReceiver -> (ArgsReceiver -> STM ()) -> STM ()
intplArgsRcvr !ets !a !exit = case a of
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
          intplExpr ets x $ \x' -> exit' $ RecvArg attrAddr Nothing $ Just x'
      Just !addr -> intplAttrAddr ets addr $ \addr' -> case maybeDefault of
        Nothing -> exit' $ RecvArg attrAddr (Just addr') Nothing
        Just !x -> intplExpr ets x
          $ \x' -> exit' $ RecvArg attrAddr (Just addr') $ Just x'

    _ -> exit' a'

intplArgSndr :: EdhThreadState -> ArgSender -> (ArgSender -> STM ()) -> STM ()
intplArgSndr !ets !a !exit' = case a of
  UnpackPosArgs !v -> intplExpr ets v $ \v' -> exit' $ UnpackPosArgs v'
  UnpackKwArgs  !v -> intplExpr ets v $ \v' -> exit' $ UnpackKwArgs v'
  UnpackPkArgs  !v -> intplExpr ets v $ \v' -> exit' $ UnpackPkArgs v'
  SendPosArg    !v -> intplExpr ets v $ \v' -> exit' $ SendPosArg v'
  SendKwArg !n !v  -> intplExpr ets v $ \v' -> exit' $ SendKwArg n v'

intplStmtSrc :: EdhThreadState -> StmtSrc -> (StmtSrc -> STM ()) -> STM ()
intplStmtSrc !ets (StmtSrc (!sp, !stmt)) !exit' =
  intplStmt ets stmt $ \stmt' -> exit' $ StmtSrc (sp, stmt')

intplStmt :: EdhThreadState -> Stmt -> (Stmt -> STM ()) -> STM ()
intplStmt !ets !stmt !exit = case stmt of
  AtoIsoStmt !x         -> intplExpr ets x $ \x' -> exit $ AtoIsoStmt x'
  GoStmt     !x         -> intplExpr ets x $ \x' -> exit $ GoStmt x'
  DeferStmt  !x         -> intplExpr ets x $ \x' -> exit $ DeferStmt x'
  LetStmt !rcvrs !sndrs -> intplArgsRcvr ets rcvrs $ \rcvrs' ->
    seqcontSTM (intplArgSndr ets <$> sndrs)
      $ \sndrs' -> exit $ LetStmt rcvrs' sndrs'
  ExtendsStmt !x           -> intplExpr ets x $ \x' -> exit $ ExtendsStmt x'
  PerceiveStmt !sink !body -> intplExpr ets sink
    $ \sink' -> intplExpr ets body $ \body' -> exit $ PerceiveStmt sink' body'
  WhileStmt !cond !act -> intplExpr ets cond
    $ \cond' -> intplStmtSrc ets act $ \act' -> exit $ WhileStmt cond' act'
  ThrowStmt  !x -> intplExpr ets x $ \x' -> exit $ ThrowStmt x'
  ReturnStmt !x -> intplExpr ets x $ \x' -> exit $ ReturnStmt x'
  ExprStmt   !x -> intplExpr ets x $ \x' -> exit $ ExprStmt x'
  _             -> exit stmt


evalLiteral :: Literal -> STM EdhValue
evalLiteral = \case
  DecLiteral    !v -> return (EdhDecimal v)
  StringLiteral !v -> return (EdhString v)
  BoolLiteral   !v -> return (EdhBool v)
  NilLiteral       -> return nil
  TypeLiteral !v   -> return (EdhType v)
  SinkCtor         -> EdhSink <$> newEventSink


evalAttrAddr :: AttrAddr -> EdhTxExit -> EdhTx
evalAttrAddr !addr !exit !ets = case addr of
  ThisRef          -> exitEdhSTM ets exit (EdhObject $ edh'scope'this scope)
  ThatRef          -> exitEdhSTM ets exit (EdhObject $ edh'scope'that scope)
  SuperRef -> throwEdhSTM ets UsageError "can not address a single super alone"
  DirectRef !addr' -> resolveEdhAttrAddr ets addr' $ \ !key ->
    lookupEdhCtxAttr scope key >>= \case
      EdhNil ->
        throwEdhSTM ets EvalError $ "not in scope: " <> T.pack (show addr')
      !val -> exitEdhSTM ets exit val
  IndirectRef !tgtExpr !addr' -> resolveEdhAttrAddr ets addr' $ \ !key ->
    runEdhTx ets $ getEdhAttr
      tgtExpr
      key
      (\ !tgtVal ->
        throwEdhTx EvalError
          $  "no such attribute "
          <> T.pack (show key)
          <> " from a "
          <> T.pack (edhTypeNameOf tgtVal)
          <> ": "
          <> T.pack (show tgtVal)
      )
      exit
 where
  !ctx   = edh'context ets
  !scope = contextScope ctx


evalDictLit
  :: [(DictKeyExpr, Expr)] -> [(EdhValue, EdhValue)] -> EdhTxExit -> EdhTx
evalDictLit [] !dsl !exit !ets = do
  !u   <- unsafeIOToSTM newUnique
  -- entry order in DictExpr is reversed as from source, we reversed it again
  -- here, so dsl now is the same order as in source code
  !dsv <- iopdFromList dsl
  exitEdhSTM ets exit $ EdhDict $ Dict u dsv
evalDictLit ((k, v) : entries) !dsl !exit !ets = case k of
  LitDictKey !lit -> runEdhTx ets $ evalExpr v $ \ !vVal _ets ->
    evalLiteral lit >>= \ !kVal ->
      runEdhTx ets $ evalDictLit entries ((kVal, vVal) : dsl) exit
  AddrDictKey !addr -> runEdhTx ets $ evalAttrAddr addr $ \ !kVal ->
    evalExpr v $ \ !vVal -> evalDictLit entries ((kVal, vVal) : dsl) exit
  ExprDictKey !kExpr -> runEdhTx ets $ evalExpr kExpr $ \ !kVal ->
    evalExpr v $ \ !vVal -> evalDictLit entries ((kVal, vVal) : dsl) exit


edhValueRepr :: EdhThreadState -> EdhValue -> (Text -> STM ()) -> STM ()
edhValueRepr !ets !val !exitRepr = case val of

  -- pair repr
  EdhPair !v1 !v2 -> edhValueRepr ets v1 $ \ !repr1 ->
    edhValueRepr ets v2 $ \ !repr2 -> exitRepr $ repr1 <> ":" <> repr2

  -- apk repr
  EdhArgsPack (ArgsPack !args !kwargs) -> if null args && odNull kwargs
    then exitRepr "()"
    else reprCSR [] args $ \ !argsCSR ->
      reprKwArgsCSR [] (odToReverseList kwargs)
        $ \ !kwargsCSR -> exitRepr $ "( " <> argsCSR <> kwargsCSR <> ")"

  -- list repr
  EdhList (List _ !ls) -> readTVar ls >>= \ !vs -> if null vs
    then exitRepr "[]"
    else reprCSR [] vs $ \ !csRepr -> exitRepr $ "[ " <> csRepr <> "]"

  -- dict repr
  EdhDict (Dict _ !ds) -> iopdToReverseList ds >>= \case
    []       -> exitRepr "{}"
    !entries -> reprDictCSR [] entries
      $ \ !entriesCSR -> exitRepr $ "{ " <> entriesCSR <> "}"

  -- object repr
  EdhObject !o -> lookupEdhObjAttr o (AttrByName "__repr__") >>= \case
    (_, EdhNil        ) -> exitRepr $ T.pack (show o)
    (_, EdhString repr) -> exitRepr repr
    (!this', EdhProcedure (EdhMethod !mth) _) ->
      runEdhTx ets
        $ callEdhMethod this' o mth (ArgsPack [] odEmpty) id
        $ \ !mthRtn _ets -> case mthRtn of
            EdhString !repr -> exitRepr repr
            _               -> edhValueRepr ets mthRtn exitRepr
    (_, EdhBoundProc (EdhMethod !mth) !this !that _) ->
      runEdhTx ets
        $ callEdhMethod this that mth (ArgsPack [] odEmpty) id
        $ \ !mthRtn _ets -> case mthRtn of
            EdhString !repr -> exitRepr repr
            _               -> edhValueRepr ets mthRtn exitRepr
    (_, reprVal) -> edhValueRepr ets reprVal exitRepr

  -- repr of named value
  EdhNamedValue !n v@EdhNamedValue{} ->
    edhValueRepr ets v $ \ !repr ->
    -- Edh operators are all left-associative, parenthesis needed
                                    exitRepr $ n <> " := (" <> repr <> ")"
  EdhNamedValue !n !v ->
    edhValueRepr ets v $ \ !repr -> exitRepr $ n <> " := " <> repr <> ""

  -- TODO handle Text repr with more performant impl. falling onto show atm.

  -- todo specially handle return/default etc. ?

  -- repr of other values simply as to show itself
  _ -> exitRepr $ T.pack $ show val

 where

  -- comma separated repr string
  reprCSR :: [Text] -> [EdhValue] -> (Text -> STM ()) -> STM ()
  reprCSR reprs [] !exit = exit $ T.concat [ i <> ", " | i <- reverse reprs ]
  reprCSR reprs (v : rest) !exit =
    edhValueRepr ets v $ \ !repr -> reprCSR (repr : reprs) rest exit
  -- comma separated repr string for kwargs
  reprKwArgsCSR
    :: [(Text, Text)] -> [(AttrKey, EdhValue)] -> (Text -> STM ()) -> STM ()
  reprKwArgsCSR !entries [] !exit' =
    exit' $ T.concat [ k <> "=" <> v <> ", " | (k, v) <- entries ]
  reprKwArgsCSR !entries ((k, v) : rest) exit' = edhValueRepr ets v
    $ \ !repr -> reprKwArgsCSR ((T.pack (show k), repr) : entries) rest exit'
  -- comma separated repr string for dict entries
  reprDictCSR
    :: [(Text, Text)] -> [(EdhValue, EdhValue)] -> (Text -> STM ()) -> STM ()
  reprDictCSR entries [] !exit' =
    exit' $ T.concat [ k <> ":" <> v <> ", " | (k, v) <- entries ]
  reprDictCSR entries ((k, v) : rest) exit' = edhValueRepr ets k $ \ !kRepr ->
    do
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
      edhValueRepr ets v $ \ !vRepr ->
        reprDictCSR ((krDecor kRepr, vrDecor vRepr) : entries) rest exit'

edhValueReprTx :: EdhValue -> EdhTxExit -> EdhTx
edhValueReprTx !val !exit !ets =
  edhValueRepr ets val $ \ !repr -> exitEdhSTM ets exit $ EdhString repr


edhValueStr :: EdhThreadState -> EdhValue -> (Text -> STM ()) -> STM ()
edhValueStr _    (EdhString !s) !exit = exit s
edhValueStr !ets !v             !exit = edhValueRepr ets v exit

edhValueStrTx :: EdhValue -> EdhTxExit -> EdhTx
edhValueStrTx !v !exit !ets =
  edhValueStr ets v $ \ !s -> exitEdhSTM ets exit $ EdhString s


defineScopeAttr :: EdhThreadState -> AttrKey -> EdhValue -> STM ()
defineScopeAttr !ets !key !val = when (key /= AttrByName "_") $ do
  if edh'ctx'eff'defining ctx
    then defEffect
    else unless (edh'ctx'pure ctx) $ iopdInsert key val (edh'scope'entity scope)
  when (edh'ctx'exporting ctx) $ case edh'obj'store $ edh'scope'this scope of
    HashStore  !hs             -> chkExport hs
    ClassStore (Class _ !cs _) -> chkExport cs
    HostStore{}                -> pure ()

 where
  !ctx     = edh'context ets
  !scope   = contextScope ctx
  !esScope = edh'scope'entity scope

  chkExport :: EntityStore -> STM ()
  chkExport !es = iopdLookup (AttrByName edhExportsMagicName) es >>= \case
    Just (EdhDict (Dict _ !dsExp)) -> iopdInsert (attrKeyValue key) val dsExp
    _                              -> do
      !d <- EdhDict <$> createEdhDict [(attrKeyValue key, val)]
      iopdInsert (AttrByName edhExportsMagicName) d es

  defEffect :: STM ()
  defEffect = iopdLookup (AttrByName edhEffectsMagicName) esScope >>= \case
    Just (EdhDict (Dict _ !dsEff)) -> iopdInsert (attrKeyValue key) val dsEff
    _                              -> do
      !d <- EdhDict <$> createEdhDict [(attrKeyValue key, val)]
      iopdInsert (AttrByName edhEffectsMagicName) d esScope


-- | Evaluate an Edh expression
evalExpr :: Expr -> EdhTxExit -> EdhTx

evalExpr (IntplSubs !val) !exit = exitEdhTx exit val

evalExpr IntplExpr{} _exit =
  throwEdhTx EvalError "bug: interpolating out side of expr range."

evalExpr (ExprWithSrc !x !sss) !exit = \ !ets -> intplExpr ets x $ \x' -> do
  let intplSrc :: SourceSeg -> (Text -> STM ()) -> STM ()
      intplSrc !ss !exit' = case ss of
        SrcSeg   !s  -> exit' s
        IntplSeg !sx -> runEdhTx ets $ evalExpr sx $ \ !val _ets ->
          edhValueRepr ets (edhDeCaseClose val) $ \ !rs -> exit' rs
  seqcontSTM (intplSrc <$> sss) $ \ssl -> do
    u <- unsafeIOToSTM newUnique
    exitEdhSTM ets exit $ EdhExpr u x' $ T.concat ssl

evalExpr (LitExpr !lit) !exit =
  \ !ets -> evalLiteral lit >>= exitEdhSTM ets exit

evalExpr (PrefixExpr PrefixPlus  !expr') !exit = evalExpr expr' exit

evalExpr (PrefixExpr PrefixMinus !expr') !exit = evalExpr expr' $ \ !val ->
  case edhDeCaseClose val of
    (EdhDecimal !v) -> exitEdhTx exit (EdhDecimal (-v))
    !v ->
      throwEdhTx EvalError
        $  "can not negate a "
        <> T.pack (edhTypeNameOf v)
        <> ": "
        <> T.pack (show v)
        <> " ❌"

evalExpr (PrefixExpr Not !expr') !exit = evalExpr expr' $ \ !val ->
  case edhDeCaseClose val of
    (EdhBool v) -> exitEdhTx exit (EdhBool $ not v)
    !v ->
      throwEdhTx EvalError
        $  "expect bool but got a "
        <> T.pack (edhTypeNameOf v)
        <> ": "
        <> T.pack (show v)
        <> " ❌"

evalExpr (PrefixExpr Guard !expr') !exit = \ !ets -> do
  let !ctx                   = edh'context ets
      !world                 = edh'ctx'world ctx
      (StmtSrc (!srcPos, _)) = edh'ctx'stmt ctx
  (consoleLogger $ edh'world'console world)
    30
    (Just $ sourcePosPretty srcPos)
    (ArgsPack [EdhString "standalone guard treated as plain value."] odEmpty)
  runEdhTx ets $ evalExpr expr' exit

evalExpr (IfExpr !cond !cseq !alt) !exit = evalExpr cond $ \ !val ->
  case edhUltimate $ edhDeCaseClose val of
    (EdhBool True ) -> evalExpr cseq exit
    (EdhBool False) -> case alt of
      Just !elseClause -> evalExpr elseClause exit
      _                -> exitEdhTx exit nil
    !v -> -- we are so strongly typed, don't coerce anything to bool
      throwEdhTx EvalError
        $  "expecting a boolean value but got a "
        <> T.pack (edhTypeNameOf v)
        <> ": "
        <> T.pack (show v)
        <> " ❌"

evalExpr (DictExpr !entries) !exit = \ !ets ->
  -- make sure dict k:v pairs are evaluated in same tx
  runEdhTx ets { edh'in'tx = True }
    $ evalDictLit entries []
    -- restore origional tx state
    $ \ !dv _ets -> exitEdhSTM ets exit dv

evalExpr (ListExpr !xs) !exit = \ !ets ->
  -- make sure list items are evaluated in same tx
  runEdhTx ets { edh'in'tx = True } $ evalExprs xs $ \ !tv _ets -> case tv of
    EdhArgsPack (ArgsPack !l _) -> do
      ll <- newTVar l
      u  <- unsafeIOToSTM newUnique
      -- restore original tx state
      exitEdhSTM ets exit (EdhList $ List u ll)
    _ -> error "bug: evalExprs returned non-apk"

evalExpr (ArgsPackExpr !argSenders) !exit = \ !ets ->
  -- make sure packed values are evaluated in same tx
  packEdhArgs ets { edh'in'tx = True } argSenders
    -- restore original tx state
    $ \ !apk -> exitEdhSTM ets exit $ EdhArgsPack apk

evalExpr (ParenExpr !x) !exit = evalExpr x exit

evalExpr (BlockExpr !stmts) !exit =
  -- a branch match should not escape out of a block, so adjacent blocks always
  -- execute sequentially
  evalBlock stmts $ \ !blkResult -> exitEdhTx exit $ edhDeCaseClose blkResult

evalExpr (CaseExpr !tgtExpr !branchesExpr) !exit =
  evalExpr tgtExpr $ \ !tgtVal !ets ->
    runEdhTx ets
        { edh'context = (edh'context ets) { edh'ctx'match = edhDeCaseClose
                                            tgtVal
                                          }
        }
      $ evalCaseBlock branchesExpr
      -- restore original tx state after block done
      $ \ !blkResult _ets -> exitEdhSTM ets exit blkResult

-- yield stmt evals to the value of caller's `do` expression
evalExpr (YieldExpr !yieldExpr) !exit =
  evalExpr yieldExpr $ \ !valToYield !ets ->
    case edh'ctx'genr'caller $ edh'context ets of
      Nothing -> throwEdhSTM ets UsageError "unexpected yield"
      Just (!etsGenrCaller, !yieldVal) ->
        yieldVal (edhDeCaseClose valToYield) $ \case
          -- give the generator procedure the chance to handle the error
          Left  !exv      -> edhThrowSTM ets exv
          -- no exception occurred in the `do` block, check its intent
          Right !doResult -> case edhDeCaseClose doResult of
            EdhContinue -> -- for loop should send nil here instead in
              -- case continue issued from the do block
                           throwEdhSTM etsGenrCaller
                                       EvalError
                                       "bug: <continue> reached yield"
            EdhBreak -> -- for loop is breaking, let the generator
              -- return nil
              -- the generator can intervene the return, that'll be
              -- black magic
              exitEdhSTM ets exit $ EdhReturn EdhNil
            EdhReturn EdhReturn{} -> -- this must be synthesiszed,
              -- in case do block issued return, the for loop wrap it as
              -- double return, so as to let the yield expr in the generator
              -- propagate the value return, as the result of the for loop
              -- the generator can intervene the return, that'll be
              -- black magic
              exitEdhSTM ets exit doResult
            EdhReturn{} -> -- for loop should have double-wrapped the
              -- return, which is handled above, in case its do block
              -- issued a return
              throwEdhSTM etsGenrCaller EvalError "bug: <return> reached yield"
            !val -> exitEdhSTM ets exit val

evalExpr (ForExpr !argsRcvr !iterExpr !doExpr) !exit = \ !ets ->
  edhForLoop ets argsRcvr iterExpr doExpr (const $ return ())
    $ \ !runLoop -> runEdhTx ets (runLoop exit)

evalExpr (PerformExpr !effAddr) !exit = \ !ets ->
  resolveEdhAttrAddr ets effAddr
    $ \ !effKey -> resolveEdhPerform ets effKey $ exitEdhSTM ets exit

evalExpr (BehaveExpr !effAddr) !exit = \ !ets -> resolveEdhAttrAddr ets effAddr
  $ \ !effKey -> resolveEdhBehave ets effKey $ exitEdhSTM ets exit

evalExpr (AttrExpr !addr) !exit = evalAttrAddr addr exit

evalExpr (CallExpr !calleeExpr !argsSndr) !exit =
  evalExpr calleeExpr $ \ !calleeVal !ets ->
    edhPrepareCall ets calleeVal argsSndr
      $ \ !mkCall -> runEdhTx ets $ mkCall exit

evalExpr (IndexExpr !ixExpr !tgtExpr) !exit = evalExpr ixExpr $ \ !ixV ->
  let !ixVal = edhDeCaseClose ixV
  in
    evalExpr tgtExpr $ \ !tgtV -> case edhDeCaseClose tgtV of

      -- indexing a dict
      (EdhDict (Dict _ !d)) -> \ !ets -> iopdLookup ixVal d >>= \case
        Nothing   -> exitEdhSTM ets exit nil
        Just !val -> exitEdhSTM ets exit val

      -- indexing an apk
      EdhArgsPack (ArgsPack !args !kwargs) -> case edhUltimate ixVal of
        EdhDecimal !idxNum -> case D.decimalToInteger idxNum of
          Just !i -> if i < 0 || i >= fromIntegral (length args)
            then
              throwEdhTx UsageError
              $  "apk index out of bounds: "
              <> T.pack (show i)
              <> " vs "
              <> T.pack (show $ length args)
            else exitEdhTx exit $ args !! fromInteger i
          Nothing ->
            throwEdhTx UsageError
              $  "invalid numeric index to an apk: "
              <> T.pack (show idxNum)
        EdhString !attrName ->
          exitEdhTx exit $ odLookupDefault EdhNil (AttrByName attrName) kwargs
        EdhSymbol !attrSym ->
          exitEdhTx exit $ odLookupDefault EdhNil (AttrBySym attrSym) kwargs
        !badIdxVal ->
          throwEdhTx UsageError $ "invalid index to an apk: " <> T.pack
            (edhTypeNameOf badIdxVal)

      -- indexing an object, by calling its ([]) method with ixVal as the single arg
      EdhObject !obj -> \ !ets ->
        lookupEdhObjAttr obj (AttrByName "[]") >>= \case

          (_, EdhNil) ->
            throwEdhSTM ets EvalError $ "no ([]) method from: " <> T.pack
              (show obj)

          (!this', EdhProcedure (EdhMethod !mth) _) ->
            runEdhTx ets
              $ callEdhMethod this' obj mth (ArgsPack [ixVal] odEmpty) id exit

          (_, EdhBoundProc (EdhMethod !mth) !this !that _) ->
            runEdhTx ets
              $ callEdhMethod this that mth (ArgsPack [ixVal] odEmpty) id exit

          (_, !badIndexer) ->
            throwEdhSTM ets EvalError
              $  "malformed index method ([]) on "
              <> T.pack (show obj)
              <> " - "
              <> T.pack (edhTypeNameOf badIndexer)
              <> ": "
              <> T.pack (show badIndexer)

      tgtVal ->
        throwEdhTx EvalError
          $  "don't know how to index "
          <> T.pack (edhTypeNameOf tgtVal)
          <> ": "
          <> T.pack (show tgtVal)
          <> " with "
          <> T.pack (edhTypeNameOf ixVal)
          <> ": "
          <> T.pack (show ixVal)

evalExpr (ExportExpr !exps) !exit = \ !ets ->
  runEdhTx ets { edh'context = (edh'context ets) { edh'ctx'exporting = True } }
    $ evalExpr exps
    $ \ !rtn -> edhSwitchState ets $ exitEdhTx exit rtn

evalExpr (ImportExpr !argsRcvr !srcExpr !maybeInto) !exit = \ !ets ->
  case maybeInto of
    Nothing ->
      let !scope = contextScope $ edh'context ets
      in  runEdhTx ets
            $ importInto (edh'scope'entity scope) argsRcvr srcExpr exit
    Just !intoExpr -> runEdhTx ets $ evalExpr intoExpr $ \ !intoVal ->
      case intoVal of
        EdhObject !intoObj -> case edh'obj'store intoObj of
          HashStore  !hs             -> importInto hs argsRcvr srcExpr exit
          ClassStore (Class _ !cs _) -> importInto cs argsRcvr srcExpr exit
          HostStore{} ->
            throwEdhTx UsageError
              $  "can not import into a host object of class "
              <> objClassName intoObj
        _ ->
          throwEdhTx UsageError
            $  "can only import into an object, not a "
            <> T.pack (edhTypeNameOf intoVal)

evalExpr (DefaultExpr !exprDef) !exit = \ !ets -> do
  u <- unsafeIOToSTM newUnique
  exitEdhSTM ets exit $ EdhDefault u exprDef (Just ets)

evalExpr expr@(InfixExpr !opSym !lhExpr !rhExpr) !exit = \ !ets ->
  let
    notApplicable !lhVal !rhVal =
      throwEdhSTM ets EvalError
        $  "operator ("
        <> opSym
        <> ") not applicable to "
        <> T.pack (edhTypeNameOf $ edhUltimate lhVal)
        <> " and "
        <> T.pack (edhTypeNameOf $ edhUltimate rhVal)

    tryMagicMethod :: EdhValue -> EdhValue -> STM () -> STM ()
    tryMagicMethod !lhVal !rhVal !naExit = case edhUltimate lhVal of
      EdhObject !lhObj -> lookupEdhObjAttr lhObj (AttrByName opSym) >>= \case
        (_, EdhNil) -> case edhUltimate rhVal of
          EdhObject !rhObj ->
            lookupEdhObjAttr rhObj (AttrByName $ opSym <> "@") >>= \case
              (_, EdhNil) -> naExit
              (!this', EdhProcedure (EdhMethod !mth) _) ->
                runEdhTx ets $ callEdhMethod this'
                                             rhObj
                                             mth
                                             (ArgsPack [lhVal] odEmpty)
                                             id
                                             chkExitMagic
              (_, EdhBoundProc (EdhMethod !mth) !this !that _) ->
                runEdhTx ets $ callEdhMethod this
                                             that
                                             mth
                                             (ArgsPack [lhVal] odEmpty)
                                             id
                                             chkExitMagic
              (_, !badEqMth) ->
                throwEdhSTM ets UsageError
                  $  "malformed magic method ("
                  <> opSym
                  <> "@) on "
                  <> T.pack (show rhObj)
                  <> " - "
                  <> T.pack (edhTypeNameOf badEqMth)
                  <> ": "
                  <> T.pack (show badEqMth)
          _ -> naExit
        (!this', EdhProcedure (EdhMethod !mth) _) ->
          runEdhTx ets $ callEdhMethod this'
                                       lhObj
                                       mth
                                       (ArgsPack [rhVal] odEmpty)
                                       id
                                       chkExitMagic
        (_, EdhBoundProc (EdhMethod !mth) !this !that _) ->
          runEdhTx ets $ callEdhMethod this
                                       that
                                       mth
                                       (ArgsPack [rhVal] odEmpty)
                                       id
                                       chkExitMagic
        (_, !badEqMth) ->
          throwEdhSTM ets UsageError
            $  "malformed magic method ("
            <> opSym
            <> ") on "
            <> T.pack (show lhObj)
            <> " - "
            <> T.pack (edhTypeNameOf badEqMth)
            <> ": "
            <> T.pack (show badEqMth)
      _ -> case edhUltimate rhVal of
        EdhObject !rhObj ->
          lookupEdhObjAttr rhObj (AttrByName $ opSym <> "@") >>= \case
            (_, EdhNil) -> naExit
            (!this', EdhProcedure (EdhMethod !mth) _) ->
              runEdhTx ets $ callEdhMethod this'
                                           rhObj
                                           mth
                                           (ArgsPack [lhVal] odEmpty)
                                           id
                                           chkExitMagic
            (_, EdhBoundProc (EdhMethod !mth) !this !that _) ->
              runEdhTx ets $ callEdhMethod this
                                           that
                                           mth
                                           (ArgsPack [lhVal] odEmpty)
                                           id
                                           chkExitMagic
            (_, !badEqMth) ->
              throwEdhSTM ets UsageError
                $  "malformed magic method ("
                <> opSym
                <> "@) on "
                <> T.pack (show rhObj)
                <> " - "
                <> T.pack (edhTypeNameOf badEqMth)
                <> ": "
                <> T.pack (show badEqMth)
        _ -> naExit
     where
      chkExitMagic :: EdhTxExit
      chkExitMagic !result _ets = case result of
        EdhDefault _ !exprDef !etsDef ->
          let !ets' = fromMaybe ets etsDef
          in  runEdhTx ets' $ evalExpr exprDef $ \ !defVal _ets ->
                case defVal of
                  EdhNil -> naExit
                  _      -> exitEdhSTM ets exit defVal
          -- `return default nil` means more defered default,
          -- that's only possible from an operator, other than
          -- the magic method we just called
        _ -> exitEdhSTM ets exit result

    callCallable :: Object -> Object -> EdhCallable -> STM ()
    callCallable !this !that !callable = case callable of

      -- calling an intrinsic operator
      EdhIntrOp _ (IntrinOpDefi _ _ iop'proc) ->
        runEdhTx ets $ iop'proc lhExpr rhExpr $ \ !rtnVal -> case rtnVal of
          EdhDefault _ !exprDef !etsDef -> evalExpr lhExpr $ \ !lhVal ->
            evalExpr rhExpr $ \ !rhVal _ets ->
              tryMagicMethod lhVal rhVal
                $ let !ets' = fromMaybe ets etsDef
                  in  runEdhTx ets' $ evalExpr exprDef $ \ !resultDef ->
                        edhSwitchState ets $ exitEdhTx exit resultDef
          _ -> edhSwitchState ets $ exitEdhTx exit rtnVal

      -- calling an operator procedure
      EdhOprtor _ !op'pred !op'proc ->
        case edh'procedure'args $ edh'procedure'decl op'proc of

          -- 2 pos-args - simple lh/rh value receiving operator
          (PackReceiver [RecvArg{}, RecvArg{}]) ->
            runEdhTx ets $ evalExpr lhExpr $ \ !lhVal ->
              evalExpr rhExpr $ \ !rhVal ->
                callEdhOperator this
                                that
                                op'proc
                                op'pred
                                [edhDeCaseClose lhVal, edhDeCaseClose rhVal]
                  $ \ !rtnVal _ets -> case rtnVal of
                      EdhDefault _ !exprDef !etsDef ->
                        tryMagicMethod lhVal rhVal
                          $ let !ets' = fromMaybe ets etsDef
                            in
                              runEdhTx ets'
                              $ evalExpr exprDef
                              $ \ !resultDef ->
                                  edhSwitchState ets $ exitEdhTx exit resultDef
                      _ -> exitEdhSTM ets exit rtnVal

          -- 3 pos-args - caller scope + lh/rh expr receiving operator
          (PackReceiver [RecvArg{}, RecvArg{}, RecvArg{}]) -> do
            lhu          <- unsafeIOToSTM newUnique
            rhu          <- unsafeIOToSTM newUnique
            scopeWrapper <- mkScopeWrapper ctx scope
            runEdhTx ets
              $ callEdhOperator
                  this
                  that
                  op'proc
                  op'pred
                  [ EdhObject scopeWrapper
                  , EdhExpr lhu lhExpr ""
                  , EdhExpr rhu rhExpr ""
                  ]
              $ \ !rtnVal -> case rtnVal of
                  EdhDefault _ !exprDef !etsDef ->
                    evalExpr lhExpr $ \ !lhVal ->
                      evalExpr rhExpr $ \ !rhVal _ets ->
                        tryMagicMethod lhVal rhVal
                          $ let !ets' = fromMaybe ets etsDef
                            in
                              runEdhTx ets'
                              $ evalExpr exprDef
                              $ \ !resultDef ->
                                  edhSwitchState ets $ exitEdhTx exit resultDef
                  _ -> edhSwitchState ets $ exitEdhTx exit rtnVal

          _ ->
            throwEdhSTM ets UsageError
              $  "invalid operator signature: "
              <> T.pack (show $ edh'procedure'args $ edh'procedure'decl op'proc)

      _ -> throwEdhSTM ets UsageError $ "invalid operator: " <> T.pack
        (show callable)

    !ctx   = edh'context ets
    !scope = contextScope ctx
  in
    resolveEdhCtxAttr scope (AttrByName opSym) >>= \case
      Nothing -> runEdhTx ets $ evalExpr lhExpr $ \ !lhVal ->
        evalExpr rhExpr $ \ !rhVal _ets ->
          tryMagicMethod lhVal rhVal $ notApplicable lhVal rhVal
      Just (!opVal, !op'lexi) ->
        let this = edh'scope'this op'lexi
            that = edh'scope'that op'lexi
        in  case opVal of
              EdhProcedure !callable _ -> callCallable this that callable
              EdhBoundProc !callable !this' !that' _ ->
                callCallable this' that' callable
              _ ->
                throwEdhSTM ets EvalError
                  $  "not callable "
                  <> T.pack (edhTypeNameOf opVal)
                  <> ": "
                  <> T.pack (show opVal)
                  <> " expressed with: "
                  <> T.pack (show expr)

-- defining an Edh class
evalExpr (ClassExpr pd@(ProcDecl !addr _ _)) !exit = \ !ets ->
  resolveEdhAttrAddr ets addr $ \ !name -> do
    let !ctx       = edh'context ets
        !scope     = contextScope ctx
        !rootScope = edh'world'root $ edh'ctx'world ctx
        !rootClass = edh'obj'class $ edh'scope'this rootScope
        !metaClass = edh'obj'class rootClass

    !idCls <- unsafeIOToSTM newUnique
    !cs    <- iopdEmpty
    !ss    <- newTVar []
    let allocator :: EdhObjectAllocator
        allocator _etsCtor _apkCtor !exitCtor =
          exitCtor =<< HashStore <$> iopdEmpty

        !clsProc = ProcDefi { edh'procedure'ident = idCls
                            , edh'procedure'name  = name
                            , edh'procedure'lexi  = scope
                            , edh'procedure'decl  = pd
                            }
        !cls    = Class clsProc cs allocator
        !clsObj = Object idCls (ClassStore cls) metaClass ss

        doExit _rtn _ets = do
          defineScopeAttr ets name $ EdhObject clsObj
          exitEdhSTM ets exit $ EdhObject clsObj

    let !clsScope = scope { edh'scope'entity = cs
                          , edh'scope'this   = clsObj
                          , edh'scope'that   = clsObj
                          , edh'scope'proc   = clsProc
                          }
        !clsCtx = ctx { edh'ctx'stack        = clsScope <| edh'ctx'stack ctx
                      , edh'ctx'genr'caller  = Nothing
                      , edh'ctx'match        = true
                      , edh'ctx'pure         = False
                      , edh'ctx'exporting    = False
                      , edh'ctx'eff'defining = False
                      }
        !etsCls = ets { edh'context = clsCtx }

    case edh'procedure'body pd of
      -- calling a host class definition
      Right !hp -> runEdhTx etsCls $ hp (ArgsPack [] odEmpty) doExit
      -- calling an Edh class definition
      Left  !pb -> runEdhTx etsCls $ evalStmt pb doExit

-- defining an Edh namespace
--
-- todo for now a namespace is implemented just as a class receiving kwargs
--      into its static attr scope initially, need sth different?
evalExpr (NamespaceExpr pd@(ProcDecl !addr _ _) !argsSndr) !exit = \ !ets ->
  packEdhArgs ets argsSndr $ \(ArgsPack !args !kwargs) -> if not (null args)
    then throwEdhSTM ets
                     UsageError
                     "you don't pass positional args to a namespace"
    else resolveEdhAttrAddr ets addr $ \ !name -> do
      let !ctx       = edh'context ets
          !scope     = contextScope ctx
          !rootScope = edh'world'root $ edh'ctx'world ctx
          !rootClass = edh'obj'class $ edh'scope'this rootScope
          !metaClass = edh'obj'class rootClass

      !idCls <- unsafeIOToSTM newUnique
      !cs    <- iopdFromList $ odToList kwargs
      !ss    <- newTVar []
      let allocator :: EdhObjectAllocator
          allocator _etsCtor _apkCtor !exitCtor =
            exitCtor =<< HashStore <$> iopdEmpty

          !clsProc = ProcDefi { edh'procedure'ident = idCls
                              , edh'procedure'name  = name
                              , edh'procedure'lexi  = scope
                              , edh'procedure'decl  = pd
                              }
          !cls    = Class clsProc cs allocator
          !clsObj = Object idCls (ClassStore cls) metaClass ss

          doExit _rtn _ets = do
            defineScopeAttr ets name $ EdhObject clsObj
            exitEdhSTM ets exit $ EdhObject clsObj

      let !clsScope = scope { edh'scope'entity = cs
                            , edh'scope'this   = clsObj
                            , edh'scope'that   = clsObj
                            , edh'scope'proc   = clsProc
                            }
          !clsCtx = ctx { edh'ctx'stack        = clsScope <| edh'ctx'stack ctx
                        , edh'ctx'genr'caller  = Nothing
                        , edh'ctx'match        = true
                        , edh'ctx'pure         = False
                        , edh'ctx'exporting    = False
                        , edh'ctx'eff'defining = False
                        }
          !etsCls = ets { edh'context = clsCtx }

      case edh'procedure'body pd of
        -- calling a host class definition
        Right !hp -> runEdhTx etsCls $ hp (ArgsPack [] odEmpty) doExit
        -- calling an Edh class definition
        Left  !pb -> runEdhTx etsCls $ evalStmt pb doExit

evalExpr (MethodExpr pd@(ProcDecl !addr _ _)) !exit = \ !ets ->
  resolveEdhAttrAddr ets addr $ \ !name -> do
    !idProc <- unsafeIOToSTM newUnique
    let !mth = EdhMethod ProcDefi
          { edh'procedure'ident = idProc
          , edh'procedure'name  = name
          , edh'procedure'lexi  = contextScope $ edh'context ets
          , edh'procedure'decl  = pd
          }
        !mthVal = EdhProcedure mth Nothing
    defineScopeAttr ets name mthVal
    exitEdhSTM ets exit mthVal

evalExpr (GeneratorExpr pd@(ProcDecl !addr _ _)) !exit = \ !ets ->
  resolveEdhAttrAddr ets addr $ \ !name -> do
    !idProc <- unsafeIOToSTM newUnique
    let !mth = EdhGnrtor ProcDefi
          { edh'procedure'ident = idProc
          , edh'procedure'name  = name
          , edh'procedure'lexi  = contextScope $ edh'context ets
          , edh'procedure'decl  = pd
          }
        !mthVal = EdhProcedure mth Nothing
    defineScopeAttr ets name mthVal
    exitEdhSTM ets exit mthVal

evalExpr (InterpreterExpr pd@(ProcDecl !addr _ _)) !exit = \ !ets ->
  resolveEdhAttrAddr ets addr $ \ !name -> do
    !idProc <- unsafeIOToSTM newUnique
    let !mth = EdhIntrpr ProcDefi
          { edh'procedure'ident = idProc
          , edh'procedure'name  = name
          , edh'procedure'lexi  = contextScope $ edh'context ets
          , edh'procedure'decl  = pd
          }
        !mthVal = EdhProcedure mth Nothing
    defineScopeAttr ets name mthVal
    exitEdhSTM ets exit mthVal

evalExpr (ProducerExpr pd@(ProcDecl !addr _ _)) !exit = \ !ets ->
  resolveEdhAttrAddr ets addr $ \ !name -> do
    !idProc <- unsafeIOToSTM newUnique
    let !mth = EdhPrducr ProcDefi
          { edh'procedure'ident = idProc
          , edh'procedure'name  = name
          , edh'procedure'lexi  = contextScope $ edh'context ets
          , edh'procedure'decl  = pd
          }
        !mthVal = EdhProcedure mth Nothing
    defineScopeAttr ets name mthVal
    exitEdhSTM ets exit mthVal



evalExpr !expr !exit = \ !ets -> case expr of


  OpDeclExpr !opSym !opPrec opProc@(ProcDecl _ _ !pb) ->
    if edh'ctx'eff'defining ctx
      then throwEdhTx UsageError "why should an operator be effectful?"
      else case pb of
        -- support re-declaring an existing operator to another name,
        -- with possibly a different precedence
        Left (StmtSrc (_, ExprStmt (AttrExpr (DirectRef (NamedAttr !origOpSym)))))
          -> do
            let
              redeclareOp !origOp = do
                unless (edh'ctx'pure ctx) $ changeEntityAttr
                  ets
                  (edh'scope'entity scope)
                  (AttrByName opSym)
                  origOp
                when (edh'ctx'exporting ctx)
                  $   lookupEdhSelfAttr (objEntity this)
                                        (AttrByName edhExportsMagicName)
                  >>= \case
                        EdhDict (Dict _ !thisExpDS) ->
                          iopdInsert (EdhString opSym) origOp thisExpDS
                        _ -> do
                          d <- EdhDict
                            <$> createEdhDict [(EdhString opSym, origOp)]
                          changeEntityAttr ets
                                           (objEntity this)
                                           (AttrByName edhExportsMagicName)
                                           d
                exitEdhSTM ets exit origOp
            lookupEdhCtxAttr ets scope (AttrByName origOpSym) >>= \case
              EdhNil ->
                throwEdhSTM ets EvalError
                  $  "original operator ("
                  <> origOpSym
                  <> ") not in scope"
              origOp@EdhIntrOp{} -> redeclareOp origOp
              origOp@EdhOprtor{} -> redeclareOp origOp
              val ->
                throwEdhSTM ets EvalError
                  $  "can not re-declare a "
                  <> T.pack (edhTypeNameOf val)
                  <> ": "
                  <> T.pack (show val)
                  <> " as an operator"
        _ -> do
          validateOperDecl ets opProc
          u <- unsafeIOToSTM newUnique
          let op = EdhOprtor
                opPrec
                Nothing
                ProcDefi { edh'procedure'ident = u
                         , edh'procedure'name  = AttrByName opSym
                         , edh'procedure'lexi  = scope
                         , edh'procedure'decl  = opProc
                         }
          unless (edh'ctx'pure ctx) $ changeEntityAttr
            ets
            (edh'scope'entity scope)
            (AttrByName opSym)
            op
          when (edh'ctx'exporting ctx)
            $   lookupEdhSelfAttr (objEntity this)
                                  (AttrByName edhExportsMagicName)
            >>= \case
                  EdhDict (Dict _ !thisExpDS) ->
                    iopdInsert (EdhString opSym) op thisExpDS
                  _ -> do
                    d <- EdhDict <$> createEdhDict [(EdhString opSym, op)]
                    changeEntityAttr ets
                                     (objEntity this)
                                     (AttrByName edhExportsMagicName)
                                     d
          exitEdhSTM ets exit op

  OpOvrdExpr !opSym !opProc !opPrec -> if edh'ctx'eff'defining ctx
    then throwEdhTx UsageError "why should an operator be effectful?"
    else do
      validateOperDecl ets opProc
      let
        findPredecessor :: STM (Maybe EdhValue)
        findPredecessor =
          lookupEdhCtxAttr ets scope (AttrByName opSym) >>= \case
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
            ProcDefi { edh'procedure'ident = u
                     , edh'procedure'name  = AttrByName opSym
                     , edh'procedure'lexi  = scope
                     , edh'procedure'decl  = opProc
                     }
      unless (edh'ctx'pure ctx)
        $ changeEntityAttr ets (edh'scope'entity scope) (AttrByName opSym) op
      when (edh'ctx'exporting ctx)
        $   lookupEdhSelfAttr (objEntity this) (AttrByName edhExportsMagicName)
        >>= \case
              EdhDict (Dict _ !thisExpDS) ->
                iopdInsert (EdhString opSym) op thisExpDS
              _ -> do
                d <- EdhDict <$> createEdhDict [(EdhString opSym, op)]
                changeEntityAttr ets
                                 (objEntity this)
                                 (AttrByName edhExportsMagicName)
                                 d
      exitEdhSTM ets exit op


validateOperDecl :: EdhThreadState -> ProcDecl -> STM ()
validateOperDecl !ets (ProcDecl _ !op'args _) = case op'args of
  -- 2 pos-args - simple lh/rh value receiving operator
  (PackReceiver [RecvArg _lhName Nothing Nothing, RecvArg _rhName Nothing Nothing])
    -> return ()
  -- 3 pos-args - caller scope + lh/rh expr receiving operator
  (PackReceiver [RecvArg _scopeName Nothing Nothing, RecvArg _lhName Nothing Nothing, RecvArg _rhName Nothing Nothing])
    -> return ()
  _ -> throwEdhSTM ets EvalError "invalid operator signature"


val2DictEntry
  :: EdhThreadState -> EdhValue -> ((ItemKey, EdhValue) -> STM ()) -> STM ()
val2DictEntry _ (EdhPair !k !v) !exit = exit (k, v)
val2DictEntry _ (EdhArgsPack (ArgsPack [!k, !v] !kwargs)) !exit
  | odNull kwargs = exit (k, v)
val2DictEntry !ets !val _ = throwEdh
  ets
  UsageError
  ("invalid entry for dict " <> T.pack (edhTypeNameOf val) <> ": " <> T.pack
    (show val)
  )

pvlToDict :: EdhThreadState -> [EdhValue] -> (DictStore -> STM ()) -> STM ()
pvlToDict !ets !pvl !exit = do
  !ds <- iopdEmpty
  let go []         = exit ds
      go (p : rest) = val2DictEntry ets p $ \(!key, !val) -> do
        iopdInsert key val ds
        go rest
  go pvl

pvlToDictEntries
  :: EdhThreadState -> [EdhValue] -> ([(ItemKey, EdhValue)] -> STM ()) -> STM ()
pvlToDictEntries !ets !pvl !exit = do
  let go !entries [] = exit entries
      go !entries (p : rest) =
        val2DictEntry ets p $ \ !entry -> go (entry : entries) rest
  go [] $ reverse pvl


edhValueNull :: EdhThreadState -> EdhValue -> (Bool -> STM ()) -> STM ()
edhValueNull _    EdhNil                   !exit = exit True
edhValueNull !ets (EdhNamedValue _ v     ) !exit = edhValueNull ets v exit
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
edhValueNull !ets (EdhObject !o) !exit =
  lookupEdhObjAttr o (AttrByName "__null__") >>= \case
    EdhNil -> exit False
    EdhMethod !nulMth ->
      runEdhTx ets
        $ callEdhMethod o nulMth (ArgsPack [] odEmpty) id
        $ \ !nulVal -> case nulVal of
            EdhBool isNull -> exit isNull
            _              -> edhValueNull ets nulVal exit
    EdhBool !b -> exit b
    badVal ->
      throwEdhSTM ets UsageError
        $  "invalid value type from __null__: "
        <> T.pack (edhTypeNameOf badVal)
edhValueNull _ _ !exit = exit False


edhIdentEqual :: EdhValue -> EdhValue -> Bool
edhIdentEqual (EdhNamedValue x'n x'v) (EdhNamedValue y'n y'v) =
  x'n == y'n && edhIdentEqual x'v y'v
edhIdentEqual EdhNamedValue{} _               = False
edhIdentEqual _               EdhNamedValue{} = False
edhIdentEqual x               y               = x == y

edhNamelyEqual
  :: EdhThreadState -> EdhValue -> EdhValue -> (Bool -> STM ()) -> STM ()
edhNamelyEqual !ets (EdhNamedValue !x'n !x'v) (EdhNamedValue !y'n !y'v) !exit =
  if x'n /= y'n then exit False else edhNamelyEqual ets x'v y'v exit
edhNamelyEqual _ EdhNamedValue{} _               !exit = exit False
edhNamelyEqual _ _               EdhNamedValue{} !exit = exit False
edhNamelyEqual !ets !x !y !exit =
  -- it's considered namely not equal if can not trivially concluded, i.e.
  -- may need to invoke magic methods or sth.
  edhValueEqual ets x y $ exit . fromMaybe False

edhValueEqual
  :: EdhThreadState -> EdhValue -> EdhValue -> (Maybe Bool -> STM ()) -> STM ()
edhValueEqual !ets !lhVal !rhVal !exit =
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
    edhValueEqual ets lhVal' rhVal' $ \case
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
      else edhValueEqual ets lhVal' rhVal' $ \case
        Just True -> cmp2Map lhRest rhRest exit'
        _         -> exit' False


resolveEdhPerform :: EdhThreadState -> AttrKey -> (EdhValue -> STM ()) -> STM ()
resolveEdhPerform !ets !effKey !exit =
  resolveEffectfulAttr ets (edhTargetStackForPerform ets) (attrKeyValue effKey)
    >>= \case
          Just (!effArt, _) -> exit effArt
          Nothing -> throwEdhSTM ets UsageError $ "no such effect: " <> T.pack
            (show effKey)
 where
  edhTargetStackForPerform :: EdhThreadState -> [Scope]
  edhTargetStackForPerform !ets = case edh'effects'stack scope of
    []         -> NE.tail $ edh'ctx'stack ctx
    outerStack -> outerStack
   where
    !ctx   = edh'context ets
    !scope = contextScope ctx

resolveEdhBehave :: EdhThreadState -> AttrKey -> (EdhValue -> STM ()) -> STM ()
resolveEdhBehave !ets !effKey !exit =
  resolveEffectfulAttr ets (edhTargetStackForBehave ets) (attrKeyValue effKey)
    >>= \case
          Just (!effArt, _) -> exit effArt
          Nothing -> throwEdhSTM ets UsageError $ "no such effect: " <> T.pack
            (show effKey)
 where
  edhTargetStackForBehave :: EdhThreadState -> [Scope]
  edhTargetStackForBehave !ets = NE.tail $ edh'ctx'stack ctx
    where !ctx = edh'context ets


parseEdhIndex
  :: EdhThreadState -> EdhValue -> (Either Text EdhIndex -> STM ()) -> STM ()
parseEdhIndex !ets !val !exit = case val of

  -- empty  
  EdhArgsPack (ArgsPack [] !kwargs') | odNull kwargs' -> exit $ Right EdhAll

  -- term
  EdhNamedValue "All" _ -> exit $ Right EdhAll
  EdhNamedValue "Any" _ -> exit $ Right EdhAny
  EdhNamedValue _ !termVal -> parseEdhIndex ets termVal exit

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
          $  "an integer expected as index number but given: "
          <> T.pack (show idxNum)

    -- term
    EdhNamedValue "All" _        -> exit' $ Right Nothing
    EdhNamedValue "Any" _        -> exit' $ Right Nothing
    EdhNamedValue _     !termVal -> sliceNum termVal exit'

    !badIdxNum -> edhValueRepr ets badIdxNum $ \ !badIdxNumRepr ->
      exit'
        $  Left
        $  "bad index number of "
        <> T.pack (edhTypeNameOf badIdxNum)
        <> ": "
        <> badIdxNumRepr


edhRegulateSlice
  :: EdhThreadState
  -> Int
  -> (Maybe Int, Maybe Int, Maybe Int)
  -> ((Int, Int, Int) -> STM ())
  -> STM ()
edhRegulateSlice !ets !len (!start, !stop, !step) !exit = case step of
  Nothing -> case start of
    Nothing -> case stop of
      Nothing     -> exit (0, len, 1)

      -- (Any:iStop:Any)
      Just !iStop -> if iStop < 0
        then
          let iStop' = len + iStop
          in  if iStop' < 0
                then
                  throwEdhSTM ets UsageError
                  $  "stop index out of bounds: "
                  <> T.pack (show iStop)
                  <> " vs "
                  <> T.pack (show len)
                else exit (0, iStop', 1)
        else if iStop > len
          then
            throwEdhSTM ets EvalError
            $  "stop index out of bounds: "
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
                  throwEdhSTM ets UsageError
                  $  "start index out of bounds: "
                  <> T.pack (show iStart)
                  <> " vs "
                  <> T.pack (show len)
                else exit (iStart', len, 1)
        else if iStart > len
          then
            throwEdhSTM ets UsageError
            $  "start index out of bounds: "
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
            throwEdhSTM ets UsageError
            $  "start index out of bounds: "
            <> T.pack (show iStart)
            <> " vs "
            <> T.pack (show len)
          else if iStop' < 0
            then
              throwEdhSTM ets EvalError
              $  "stop index out of bounds: "
              <> T.pack (show iStop)
              <> " vs "
              <> T.pack (show len)
            else if iStart' <= iStop'
              then
                (if iStop' > len
                  then
                    throwEdhSTM ets EvalError
                    $  "stop index out of bounds: "
                    <> T.pack (show iStop)
                    <> " vs "
                    <> T.pack (show len)
                  else if iStart' >= len
                    then
                      throwEdhSTM ets UsageError
                      $  "start index out of bounds: "
                      <> T.pack (show iStart)
                      <> " vs "
                      <> T.pack (show len)
                    else exit (iStart', iStop', 1)
                )
              else
                (if iStop' >= len
                  then
                    throwEdhSTM ets EvalError
                    $  "stop index out of bounds: "
                    <> T.pack (show iStop)
                    <> " vs "
                    <> T.pack (show len)
                  else if iStart' > len
                    then
                      throwEdhSTM ets UsageError
                      $  "start index out of bounds: "
                      <> T.pack (show iStart)
                      <> " vs "
                      <> T.pack (show len)
                    else exit (iStart', iStop', -1)
                )

  Just !iStep -> if iStep == 0
    then throwEdhSTM ets UsageError "step can not be zero in slice"
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
                    throwEdhSTM ets EvalError
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
                  throwEdhSTM ets UsageError
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
                  throwEdhSTM ets UsageError
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
                        throwEdhSTM ets EvalError
                        $  "Backward stop index out of bounds: "
                        <> T.pack (show iStop)
                        <> " vs "
                        <> T.pack (show len)
                      else if iStart' < iStop'
                        then
                          throwEdhSTM ets EvalError
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
                  throwEdhSTM ets EvalError
                  $  "stop index out of bounds: "
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
                  throwEdhSTM ets UsageError
                  $  "start index out of bounds: "
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
                  throwEdhSTM ets EvalError
                  $  "Can not step from "
                  <> T.pack (show iStart)
                  <> " to "
                  <> T.pack (show iStop)
                else exit (iStart', iStop', iStep)
        )


edhRegulateIndex :: EdhThreadState -> Int -> Int -> (Int -> STM ()) -> STM ()
edhRegulateIndex !ets !len !idx !exit =
  let !posIdx = if idx < 0  -- Python style negative index
        then idx + len
        else idx
  in  if posIdx < 0 || posIdx >= len
        then
          throwEdhSTM ets EvalError
          $  "Index out of bounds: "
          <> T.pack (show idx)
          <> " vs "
          <> T.pack (show len)
        else exit posIdx

