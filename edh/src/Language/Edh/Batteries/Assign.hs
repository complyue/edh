
module Language.Edh.Batteries.Assign where

import           Prelude
-- import           Debug.Trace

import           Control.Monad.Reader

import           Control.Concurrent.STM

import qualified Data.Text                     as T

import qualified Data.HashMap.Strict           as Map

import           Language.Edh.Control
import           Language.Edh.Details.RtTypes
import           Language.Edh.Details.CoreLang
import           Language.Edh.Details.Evaluate


-- | operator (=)
assignProc :: EdhIntrinsicOp
assignProc !lhExpr !rhExpr !exit = ask >>= \ !pgs ->
  local
      (const pgs {
            -- execution of the assignment always in a tx for atomicity
                   edh'in'tx   = True
                 , edh'context = (edh'context pgs) {
            -- discourage artifact definition during assignment
                                                     contextPure = True }
                 }
      )
    $ case lhExpr of
        IndexExpr ixExpr tgtExpr ->
          evalExpr ixExpr $ \(OriginalValue !ixV _ _) ->
            let !ixVal = edhDeCaseClose ixV
            in
              -- indexing assignment
              evalExpr rhExpr $ \(OriginalValue !rhV _ _) ->
                let !rhVal = edhDeCaseClose rhV
                in
                  evalExpr tgtExpr $ \(OriginalValue !tgtVal _ _) ->
                    case edhUltimate tgtVal of

                      -- indexing assign to a dict
                      EdhDict (Dict _ !d) -> contEdhSTM $ do
                        modifyTVar' d $ setDictItem ixVal rhVal
                        exitEdhSTM pgs exit rhVal

                      -- indexing assign to an object, by calling its ([=])
                      -- method with ixVal and rhVal as the args
                      EdhObject obj ->
                        contEdhSTM
                          $   lookupEdhObjAttr pgs obj (AttrByName "[=]")
                          >>= \case
                                EdhNil ->
                                  throwEdhSTM pgs EvalError
                                    $  "No ([=]) method from: "
                                    <> T.pack (show obj)
                                EdhMethod !mth'proc ->
                                  -- enforced tx boundary cut just before
                                  -- magic method call, after args prepared
                                  runEdhProc pgs $ callEdhMethod
                                    obj
                                    mth'proc
                                    (ArgsPack [ixVal, rhVal] Map.empty)
                                    id
                                    exit
                                !badIndexer ->
                                  throwEdhSTM pgs EvalError
                                    $  "Malformed index method ([=]) on "
                                    <> T.pack (show obj)
                                    <> " - "
                                    <> T.pack (edhTypeNameOf badIndexer)
                                    <> ": "
                                    <> T.pack (show badIndexer)

                      _ ->
                        local (const pgs)
                          $  throwEdh EvalError
                          $  "Don't know how to index assign "
                          <> T.pack (edhTypeNameOf tgtVal)
                          <> ": "
                          <> T.pack (show tgtVal)
                          <> " with "
                          <> T.pack (edhTypeNameOf ixVal)
                          <> ": "
                          <> T.pack (show ixVal)

        _ -> evalExpr rhExpr $ \(OriginalValue !rhVal _ _) ->
          assignEdhTarget pgs lhExpr exit $ edhDeCaseClose rhVal


-- | operator (?=)
assignMissingProc :: EdhIntrinsicOp
assignMissingProc (AttrExpr (DirectRef (NamedAttr "_"))) _ _ =
  throwEdh UsageError "Not so reasonable: _ ?= xxx"
assignMissingProc (AttrExpr (DirectRef !addr)) !rhExpr !exit = ask >>= \pgs ->
  contEdhSTM $ resolveEdhAttrAddr pgs addr $ \key -> do
    let !ent      = scopeEntity $ contextScope $ edh'context pgs
        pgsAssign = pgs
          {
            -- execution of the assignment always in a tx for atomicity
            edh'in'tx   = True
          , edh'context = (edh'context pgs) {
            -- discourage artifact definition during assignment
                                              contextPure = True }
          }
    lookupEntityAttr pgsAssign ent key >>= \case
      EdhNil ->
        runEdhProc pgsAssign $ evalExpr rhExpr $ \(OriginalValue !rhV _ _) ->
          let !rhVal = edhDeCaseClose rhV
          in  contEdhSTM $ do
                changeEntityAttr pgsAssign ent key rhVal
                exitEdhSTM pgs exit rhVal
      !preVal -> exitEdhSTM pgs exit preVal
assignMissingProc !lhExpr _ _ =
  throwEdh EvalError $ "Invalid left-hand expression to (?=) " <> T.pack
    (show lhExpr)

