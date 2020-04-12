
module Language.Edh.Parser where

import           Prelude
-- import           Debug.Trace

import           Control.Applicative     hiding ( many
                                                , some
                                                )
import           Control.Monad
import           Control.Monad.State.Strict

import           Data.Functor
import qualified Data.Char                     as Char
import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import           Data.Scientific
import qualified Data.HashMap.Strict           as Map

import           Text.Megaparsec
import           Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer    as L

import           Data.Lossless.Decimal         as D

import           Language.Edh.Control
import           Language.Edh.Details.RtTypes


sc :: Parser ()
sc = L.space space1 (L.skipLineComment "#") (L.skipBlockComment "{#" "#}")

symbol :: Text -> Parser Text
symbol = L.symbol sc

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

keyword :: Text -> Parser Text
keyword kw = try $ lexeme (string kw <* notFollowedBy (satisfy isIdentChar))

trailingComma :: Parser ()
trailingComma = void $ optional $ symbol ","

optionalSemicolon :: Parser ()
optionalSemicolon = void $ optional $ symbol ";"


isLetter :: Char -> Bool
isLetter = flip elem $ '_' : ['a' .. 'z'] ++ ['A' .. 'Z']

isIdentChar :: Char -> Bool
isIdentChar c = isLetter c || isDigit c || c == '\''

isDigit :: Char -> Bool
isDigit = flip elem ['0' .. '9']

isOperatorChar :: Char -> Bool
isOperatorChar c = if c > toEnum 128
  then Char.isSymbol c
  else elem c ("=~!@#$%^&|:<>?+-*/" :: [Char])

parseProgram :: Parser [StmtSrc]
parseProgram = sc *> many parseStmt <* eof

parseVoidStmt :: Parser Stmt
parseVoidStmt = VoidStmt <$ symbol "pass" -- same as Python

parseAtoIsoStmt :: Parser Stmt
parseAtoIsoStmt = AtoIsoStmt <$> (keyword "ai" >> parseExpr)

parseGoStmt :: Parser Stmt
parseGoStmt = do
  void $ keyword "go"
  errRptPos <- getOffset
  expr      <- parseExpr
  case expr of
    BlockExpr{} -> return ()
    CaseExpr{}  -> return ()
    CallExpr{}  -> return ()
    ForExpr{}   -> return ()
    _           -> do
      setOffset errRptPos
      fail "A block, case, call or for loop should be here"
  return $ GoStmt expr

parseDeferStmt :: Parser Stmt
parseDeferStmt = do
  void $ keyword "defer"
  errRptPos <- getOffset
  expr      <- parseExpr
  case expr of
    BlockExpr{} -> return ()
    CaseExpr{}  -> return ()
    CallExpr{}  -> return ()
    ForExpr{}   -> return ()
    _           -> do
      setOffset errRptPos
      fail "A block, case, call or for loop should be here"
  return $ DeferStmt expr

parseImportStmt :: Parser Stmt
parseImportStmt = do
  void $ keyword "import"
  liftA2 ImportStmt parseArgsReceiver parseExpr

parseLetStmt :: Parser Stmt
parseLetStmt = do
  void $ keyword "let"
  receiver <- parseArgsReceiver
  void $ symbol "="
  LetStmt receiver <$> parseArgsSender

parseArgsReceiver :: Parser ArgsReceiver
parseArgsReceiver = (symbol "*" $> WildReceiver) <|> parsePackReceiver <|> do
  singleArg <- parseKwRecv False
  return $ SingleReceiver singleArg

parsePackReceiver :: Parser ArgsReceiver
parsePackReceiver = between
  (symbol "(")
  (symbol ")")
  (parseArgRecvs [] False False >>= return . PackReceiver . reverse)

parseArgRecvs :: [ArgReceiver] -> Bool -> Bool -> Parser [ArgReceiver]
parseArgRecvs rs kwConsumed posConsumed =
  (lookAhead (symbol ")") >> return rs) <|> do
    nextArg <-
      (if posConsumed
          then restPkArgs <|> restKwArgs <|> parseKwRecv True
          else nextPosArg
        )
        <* trailingComma
    case nextArg of
      RecvRestPosArgs _ -> parseArgRecvs (nextArg : rs) kwConsumed True
      RecvRestKwArgs  _ -> parseArgRecvs (nextArg : rs) True posConsumed
      _                 -> parseArgRecvs (nextArg : rs) kwConsumed posConsumed
 where
  nextPosArg, restKwArgs, restPosArgs :: Parser ArgReceiver
  nextPosArg = restPkArgs <|> restKwArgs <|> restPosArgs <|> parseKwRecv True
  restPkArgs = do
    void $ symbol "***"
    RecvRestPkArgs <$> parseAttrName
  restKwArgs = do
    void $ symbol "**"
    RecvRestKwArgs <$> parseAttrName
  restPosArgs = do
    void $ symbol "*"
    RecvRestPosArgs <$> parseAttrName

parseRetarget :: Parser AttrAddr
parseRetarget = do
  void $ keyword "as"
  parseAttrAddr

parseArgLetExpr :: Parser Expr
parseArgLetExpr = do
  void $ symbol "="
  parseExpr

parseKwRecv :: Bool -> Parser ArgReceiver
parseKwRecv inPack = do
  aname   <- parseAttrName
  retgt   <- optional parseRetarget
  defExpr <- if inPack then optional parseArgLetExpr else return Nothing
  return $ RecvArg aname (validateTgt retgt) defExpr
 where
  validateTgt :: Maybe AttrAddr -> Maybe AttrAddr
  validateTgt tgt = case tgt of
    Nothing      -> Nothing
    Just ThisRef -> fail "Can not overwrite this"
    Just ThatRef -> fail "Can not overwrite that"
    _            -> tgt


parseAttrAddr :: Parser AttrAddr
parseAttrAddr = do
  p1 <- leadingPart
  moreAddr p1
 where
  leadingPart :: Parser Expr
  leadingPart = choice
    [ AttrExpr ThisRef <$ keyword "this"
    , AttrExpr ThatRef <$ keyword "that"
    , AttrExpr SuperRef <$ keyword "super"
    , AttrExpr . DirectRef . SymbolicAttr <$> parseAttrSym
    , AttrExpr . DirectRef . NamedAttr <$> parseAttrName
    ]
  followingPart :: Parser Expr
  followingPart = choice
    [ keyword "this" *> fail "Unexpected this reference"
    , AttrExpr . DirectRef . SymbolicAttr <$> parseAttrSym
    , AttrExpr . DirectRef . NamedAttr <$> parseAttrName
    ]
  moreAddr :: Expr -> Parser AttrAddr
  moreAddr p1 =
    (symbol "." *> followingPart >>= \case
        AttrExpr (DirectRef addr) ->
          let r1 = IndirectRef p1 addr in moreAddr (AttrExpr r1) <|> return r1
        _ -> error "bug"
      )
      <|> case p1 of
            AttrExpr ThisRef -> return ThisRef
            AttrExpr ThatRef -> return ThatRef
            AttrExpr r1      -> return r1
            _                -> error "bug"


parseArgsSender :: Parser ArgsSender
parseArgsSender = parsePackSender <|> do
  (: []) . SendPosArg <$> parseExpr

parsePackSender :: Parser ArgsSender
parsePackSender =
  between (symbol "(") (symbol ")") $ reverse <$> parseArgSends []

parseArgSends :: [ArgSender] -> Parser [ArgSender]
parseArgSends ss = (lookAhead (symbol ")") >> return ss) <|> do
  arg <- nextArg <* trailingComma
  parseArgSends $ arg : ss
 where
  nextArg, unpackPkArgs, unpackKwArgs, unpackPosArgs :: Parser ArgSender
  nextArg      = unpackPkArgs <|> unpackKwArgs <|> unpackPosArgs <|> parseKwSend
  unpackPkArgs = do
    void $ symbol "***"
    UnpackPkArgs <$> parseExpr
  unpackKwArgs = do
    void $ symbol "**"
    UnpackKwArgs <$> parseExpr
  unpackPosArgs = do
    void $ symbol "*"
    UnpackPosArgs <$> parseExpr
  parseKwSend :: Parser ArgSender
  parseKwSend = do
    errRptPos <- getOffset
    parseExpr >>= \case
      InfixExpr "=" nExpr vExpr -> case nExpr of
        AttrExpr (DirectRef (NamedAttr attrName)) ->
          return $ SendKwArg attrName vExpr
        _ -> do
          setOffset errRptPos
          fail $ "Invalid argument name: " <> show nExpr
      vExpr -> return $ SendPosArg vExpr


parseClassStmt :: Parser Stmt
parseClassStmt = ClassStmt <$> (keyword "class" >> parseClassDecl)
 where
  parseClassDecl = liftA3 ProcDecl
                          parseAlphaName
                          (return $ PackReceiver [])
                          (Left <$> parseStmt)

parseExtendsStmt :: Parser Stmt
parseExtendsStmt = ExtendsStmt <$> (keyword "extends" >> parseExpr)

parseMethodStmt :: Parser Stmt
parseMethodStmt = MethodStmt <$> (keyword "method" >> parseProcDecl)

parseGeneratorStmt :: Parser Stmt
parseGeneratorStmt = GeneratorStmt <$> (keyword "generator" >> parseProcDecl)

parsePerceiveStmt :: Parser Stmt
parsePerceiveStmt =
  keyword "perceive" >> liftA2 PerceiveStmt parseAttrAddr parseExpr

parseInterpreterStmt :: Parser Stmt
parseInterpreterStmt =
  InterpreterStmt <$> (keyword "interpreter" >> parseProcDecl)

parseProducerStmt :: Parser Stmt
parseProducerStmt = ProducerStmt <$> (keyword "producer" >> parseProcDecl)

parseWhileStmt :: Parser Stmt
parseWhileStmt = do
  void $ keyword "while"
  liftA2 WhileStmt parseExpr parseExpr

parseProcDecl :: Parser ProcDecl
parseProcDecl = liftA3 ProcDecl
                       (parseMagicProcName <|> parseAlphaName)
                       parseArgsReceiver
                       (Left <$> parseStmt)

parseMagicProcName :: Parser Text
parseMagicProcName = between (symbol "(") (symbol ")") $ lexeme $ takeWhile1P
  (Just "magic procedure name")
  isMagicProcChar

-- to allow magic method names like ([]) ([=]) etc.
isMagicProcChar :: Char -> Bool
isMagicProcChar c = isOperatorChar c || elem c ("[]" :: [Char])

parseOpDeclOvrdStmt :: Parser Stmt
parseOpDeclOvrdStmt = do
  void $ keyword "operator"
  srcPos    <- getSourcePos
  errRptPos <- getOffset
  opSym     <- parseOpLit
  precDecl  <- optional $ L.decimal <* sc
  -- todo restrict forms of valid args receiver for operators, e.g. 
  --  * 2 pos-args - simple lh/rh value receiving operator
  --  * 3 pos-args - caller scope + lh/rh expr receiving operator
  argRcvr   <- parseArgsReceiver
  body      <- parseStmt
  let procDecl = ProcDecl opSym argRcvr (Left body)
  opPD <- get
  case precDecl of
    Nothing -> case Map.lookup opSym opPD of
      Nothing -> do
        setOffset errRptPos
        fail
          $  "You forget to specify the precedence for operator: "
          <> T.unpack opSym
          <> " ?"
      Just (opPrec, _) -> return $ OpOvrdStmt opSym procDecl opPrec
    Just opPrec -> do
      when (opPrec < 0 || opPrec >= 10) $ do
        setOffset errRptPos
        fail $ "Invalid operator precedence: " <> show opPrec
      case Map.lookup opSym opPD of
        Nothing       -> return ()
        Just (_, odl) -> do
          setOffset errRptPos
          fail
            $  "Redeclaring operator "
            <> T.unpack opSym
            <> " which has been declared at "
            <> T.unpack odl
            <> ", omit the precedence if you mean to override it."
      put $ Map.insert opSym (opPrec, T.pack $ sourcePosPretty srcPos) opPD
      return $ OpDeclStmt opSym opPrec procDecl

parseReturnStmt :: Parser Stmt
parseReturnStmt = do
  void $ keyword "return"
  ReturnStmt <$> parseExpr

parseThrowStmt :: Parser Stmt
parseThrowStmt = do
  void $ keyword "throw"
  ThrowStmt <$> parseExpr


parseStmt :: Parser StmtSrc
parseStmt = optionalSemicolon *> do
  srcPos <- getSourcePos
  StmtSrc
    .   (srcPos, )
    <$> choice
          [ parseAtoIsoStmt
          , parseGoStmt
          , parseDeferStmt
          , parseImportStmt
          , parseLetStmt
          , parseClassStmt
          , parseExtendsStmt
          , parseMethodStmt
          , parseGeneratorStmt
          , parsePerceiveStmt
          , parseInterpreterStmt
          , parseProducerStmt
          , parseWhileStmt
          -- TODO validate break/continue must within a loop construct
          , BreakStmt <$ keyword "break"
          , ContinueStmt <$ keyword "continue"
          -- TODO validate fallthrough must within a branch block
          , FallthroughStmt <$ keyword "fallthrough"
          , parseOpDeclOvrdStmt
          -- TODO validate yield must within a generator procedure
          , parseReturnStmt
          , parseThrowStmt
          , parseVoidStmt

          -- NOTE: statements above should probably all be detected by
          -- `illegalExprStart` as invalid start for an expr
          , ExprStmt <$> parseExpr
          ]
    <*  optionalSemicolon


parseIfExpr :: Parser Expr
parseIfExpr = do
  void $ keyword "if"
  cond <- parseExpr
  void $ keyword "then"
  cseq <- parseExpr
  alt  <- optional $ do
    void $ keyword "else"
    parseExpr
  return $ IfExpr cond cseq alt

parseCaseExpr :: Parser Expr
parseCaseExpr = do
  void $ keyword "case"
  tgt <- parseExpr
  void $ keyword "of"
  CaseExpr tgt <$> parseExpr

parseYieldExpr :: Parser Expr
parseYieldExpr = do
  void $ keyword "yield"
  YieldExpr <$> parseExpr

parseForExpr :: Parser Expr
parseForExpr = do
  void $ keyword "for"
  ar <- parseArgsReceiver
  void $ keyword "from"
  iter <- parseExpr
  void $ keyword "do"
  ForExpr ar iter <$> parseExpr

parseListExpr :: Parser Expr
parseListExpr = ListExpr
  <$> between (symbol "[") (symbol "]") (many (parseExpr <* trailingComma))

parseStringLit :: Parser Text
parseStringLit = lexeme $ do
  delim <- char '\"' <|> char '\'' <|> char '`'
  T.pack <$> manyTill L.charLiteral (char delim)

parseBoolLit :: Parser Bool
parseBoolLit =
  (keyword "true" *> return True) <|> (keyword "false" *> return False)

parseDecLit :: Parser Decimal
parseDecLit = lexeme $ do -- todo support HEX/OCT ?
  sn <- L.signed (return ()) L.scientific
  return $ Decimal 1 (fromIntegral $ base10Exponent sn) (coefficient sn)

parseLitExpr :: Parser Literal
parseLitExpr = choice
  [ NilLiteral <$ litKw "nil"
  , BoolLiteral <$> parseBoolLit
  , StringLiteral <$> parseStringLit
  , SinkCtor <$ litKw "sink"
  , DecLiteral D.nan <$ litKw "nan"
  , DecLiteral D.inf <$ litKw "inf"
  , DecLiteral <$> parseDecLit
  , TypeLiteral DecimalType <$ litKw "DecimalType"
  , TypeLiteral BoolType <$ litKw "BoolType"
  , TypeLiteral StringType <$ litKw "StringType"
  , TypeLiteral SymbolType <$ litKw "SymbolType"
  , TypeLiteral ObjectType <$ litKw "ObjectType"
  , TypeLiteral DictType <$ litKw "DictType"
  , TypeLiteral ListType <$ litKw "ListType"
  , TypeLiteral PairType <$ litKw "PairType"
  , TypeLiteral TupleType <$ litKw "TupleType"
  , TypeLiteral ArgsPackType <$ litKw "ArgsPackType"
  , TypeLiteral BlockType <$ litKw "BlockType"
  , TypeLiteral IntrinsicType <$ litKw "IntrinsicType"
  , TypeLiteral HostClassType <$ litKw "HostClassType"
  , TypeLiteral HostMethodType <$ litKw "HostMethodType"
  , TypeLiteral HostOperType <$ litKw "HostOperType"
  , TypeLiteral HostGenrType <$ litKw "HostGenrType"
  , TypeLiteral ClassType <$ litKw "ClassType"
  , TypeLiteral MethodType <$ litKw "MethodType"
  , TypeLiteral OperatorType <$ litKw "OperatorType"
  , TypeLiteral GeneratorType <$ litKw "GeneratorType"
  , TypeLiteral InterpreterType <$ litKw "InterpreterType"
  , TypeLiteral ProducerType <$ litKw "ProducerType"
  , TypeLiteral BreakType <$ litKw "BreakType"
  , TypeLiteral ContinueType <$ litKw "ContinueType"
  , TypeLiteral CaseCloseType <$ litKw "CaseCloseType"
  , TypeLiteral FallthroughType <$ litKw "FallthroughType"
  , TypeLiteral YieldType <$ litKw "YieldType"
  , TypeLiteral ReturnType <$ litKw "ReturnType"
  , TypeLiteral SinkType <$ litKw "SinkType"
  , TypeLiteral ExprType <$ litKw "ExprType"
  , TypeLiteral TypeType <$ litKw "TypeType"
  ]
  where
        -- | there're just too many of them,
        -- annoying if all listed in err rpt
        litKw = hidden . keyword

parseAttrName :: Parser Text
parseAttrName = parseOpName <|> parseAlphaName

parseAttrSym :: Parser AttrName
parseAttrSym = char '@' *> parseAlphaName

parseAlphaName :: Parser AttrName
parseAlphaName = lexeme $ do
  anStart <- takeWhile1P (Just "attribute name") isLetter
  anRest  <- takeWhileP Nothing isIdentChar
  return $ anStart <> anRest

parseOpName :: Parser Text
parseOpName = between (symbol "(") (symbol ")") parseOpLit

parseOpLit :: Parser Text
parseOpLit = lexeme $ takeWhile1P (Just "operator symbol") isOperatorChar

parseBlockOrDict :: Parser Expr
parseBlockOrDict = choice [try parseBlock, parseDict]

parseBlock :: Parser Expr
parseBlock =
  symbol "{" *> notFollowedBy (symbol ",") *> parseBlockRest False []
 where
  parseBlockRest :: Bool -> [StmtSrc] -> Parser Expr
  parseBlockRest mustBlock t = do
    mustBlock' <- optional (symbol ";") >>= \case
      Nothing -> return mustBlock
      _       -> return True
    choice
      [ symbol "}"
        $> (case t of
             [] | mustBlock' -> BlockExpr []
            -- let {} parse as empty dict instead of empty block
             []              -> DictExpr []
            -- single k:v pair without comma will reach here
             [StmtSrc (_, ExprStmt pairExpr@(InfixExpr ":" _ _))]
               | not mustBlock' -> DictExpr [pairExpr]
             _ -> BlockExpr (reverse t)
           )
      , do
        ss <- parseStmt
        parseBlockRest mustBlock' $ ss : t
      ]

parseDict :: Parser Expr
parseDict = symbol "{" *> parseDictRest []
 where
  parseDictRest :: [Expr] -> Parser Expr
  parseDictRest t = optional (symbol ",") *> choice
    [ symbol "}" $> DictExpr (reverse t)
    , parseKeyValPair >>= \p -> parseDictRest $ p : t
    ]
  parseKeyValPair :: Parser Expr
  parseKeyValPair = do
    pairExpr <- parseExpr
    trailingComma
    case pairExpr of
      InfixExpr ":" _ _ -> return pairExpr
      _                 -> fail $ "Invalid dict entry: " <> show pairExpr


parseOpAddrOrTupleOrParen :: Parser Expr
parseOpAddrOrTupleOrParen =
  symbol "("
    *> (   (AttrExpr . DirectRef . NamedAttr <$> (parseOpLit <* symbol ")"))
       <|> parseTupleRest ")" False []
       )

parseTupleRest :: Text -> Bool -> [Expr] -> Parser Expr
parseTupleRest closeSym mustTuple t = do
  mustTuple' <- optional (symbol ",") >>= \case
    Nothing -> return mustTuple
    _       -> return True
  choice
    [ symbol closeSym
      $> (case t of
           [singleExpr] | not mustTuple' ->
             if closeSym == ")" then ParenExpr singleExpr else singleExpr
           _ -> TupleExpr (reverse t)
         )
    , parseExpr >>= \e -> parseTupleRest closeSym mustTuple' $ e : t
    ]

parseIndexer :: Parser Expr
parseIndexer = symbol "[" *> parseTupleRest "]" False []


-- Notes:
--  * (+)/(-) prefix should have highest precedence below Call/Index
--  * (not) should have a precedence slightly higher than (&&) (||)
--  * guard (|) should have a precedence no smaller than the branch op (->)

parsePrefixExpr :: Parser Expr
parsePrefixExpr = choice
  [ (symbol "+" >> notFollowedBy (satisfy isOperatorChar))
  >>  PrefixExpr PrefixPlus
  <$> parseExprPrec 9
  , (symbol "-" >> notFollowedBy (satisfy isOperatorChar))
  >>  PrefixExpr PrefixMinus
  <$> parseExprPrec 9
  , keyword "not" >> PrefixExpr Not <$> parseExprPrec 4
  , (symbol "|" >> notFollowedBy (satisfy isOperatorChar))
  >>  PrefixExpr Guard
  <$> parseExprPrec 1
  ]


-- NOTE: a keyword for statement will parse as identifier in an expr,
--       if not forbidden here.
illegalExprStart :: Parser Bool
illegalExprStart =
  True
    <$  choice
          [ keyword "ai"
          , keyword "go"
          , keyword "defer"
          , keyword "import"
          , keyword "let"
          , keyword "class"
          , keyword "extends"
          , keyword "method"
          , keyword "generator"
          , keyword "perceive"
          , keyword "interpreter"
          , keyword "producer"
          , keyword "while"
          , keyword "break"
          , keyword "continue"
          , keyword "fallthrough"
          , keyword "operator"
          , keyword "return"
          , keyword "throw"
          , keyword "pass"
          ]
    <|> return False


-- besides hardcoded prefix operators, all other operators are infix binary
-- operators, they can be declared and further overridden everywhere,
-- while they are left-assosciative only

parseExprPrec :: Precedence -> Parser Expr
parseExprPrec prec = do
  s <- getInput
  o <- getOffset
  fst <$> parseExprPrecWithSrc prec (s, o, [])

parseExprLit :: Parser Expr
parseExprLit = do
  void $ keyword "expr"
  s                  <- getInput
  o                  <- getOffset
  (x, (s', o', sss)) <- parseExprPrecWithSrc (-20) (s, o, [])
  o''                <- getOffset
  sss'               <- if o'' <= o'
    then return sss
    else do
      let !src = maybe "" fst $ takeN_ (o'' - o') s'
      return $ SrcSeg src : sss
  return $ ExprWithSrc x $ reverse sss'

parseIntplExpr :: IntplSrcInfo -> Parser (Expr, IntplSrcInfo)
parseIntplExpr (s, o, sss) = do
  o' <- getOffset
  void $ symbol "{$"
  x <- parseExprPrec (-30)
  let !sss' = if o' > o
        then SrcSeg (maybe "" fst $ takeN_ (o' - o) s) : sss
        else sss
      !sss'' = IntplSeg x : sss'
  void $ string "$}" -- reserve spaces following this in original source
  s'  <- getInput
  o'' <- getOffset
  void $ optional sc -- but consume the optional spaces wrt parsing
  return (IntplExpr x, (s', o'', sss''))

type IntplSrcInfo = (Text, Int, [SourceSeg])

parseExprPrecWithSrc
  :: Precedence -> IntplSrcInfo -> Parser (Expr, IntplSrcInfo)
parseExprPrecWithSrc prec si = lookAhead illegalExprStart >>= \case
  True  -> fail "Illegal expression"
  False -> ((, si) <$> parseExprLit) <|> parseIntplExpr si <|> do
    x <- choice
      [ parsePrefixExpr
      , parseYieldExpr
      , parseForExpr
      , parseIfExpr
      , parseCaseExpr
      , parseListExpr
      , parseBlockOrDict
      , parseOpAddrOrTupleOrParen
      , LitExpr <$> parseLitExpr
      , AttrExpr <$> parseAttrAddr
      ]
    parseMoreOps x
 where
  parseMoreOps :: Expr -> Parser (Expr, IntplSrcInfo)
  parseMoreOps expr = choice
    [ parseIndexer >>= parseMoreOps . flip IndexExpr expr
    , parsePackSender >>= parseMoreOps . CallExpr expr
    , parseMoreInfix si expr
    ]
  parseMoreInfix :: IntplSrcInfo -> Expr -> Parser (Expr, IntplSrcInfo)
  parseMoreInfix si' leftExpr = choice
    [ lookAhead (symbol "$}") >> return (leftExpr, si')
    , higherOp prec >>= \case
      Nothing              -> return (leftExpr, si')
      Just (opPrec, opSym) -> do
        (rightExpr, si'') <- parseExprPrecWithSrc opPrec si'
        parseMoreInfix si'' $ InfixExpr opSym leftExpr rightExpr
    ]

  higherOp :: Precedence -> Parser (Maybe (Precedence, OpSymbol))
  higherOp prec' = do
    beforeOp  <- getParserState
    errRptPos <- getOffset
    optional parseOpLit >>= \case
      Nothing    -> return Nothing
      Just opSym -> do
        opPD <- get
        case Map.lookup opSym opPD of
          Nothing -> do
            setOffset errRptPos
            fail $ "Undeclared operator: " <> T.unpack opSym
          Just (opPrec, _) -> if opPrec > prec'
            then return $ Just (opPrec, opSym)
            else do
              -- leave this op to be encountered later, i.e.
              -- after left-hand expr collapsed into one
              setParserState beforeOp
              return Nothing


parseExpr :: Parser Expr
parseExpr = parseExprPrec (-10)

parseExprWithSrc :: IntplSrcInfo -> Parser (Expr, IntplSrcInfo)
parseExprWithSrc = parseExprPrecWithSrc (-10)
