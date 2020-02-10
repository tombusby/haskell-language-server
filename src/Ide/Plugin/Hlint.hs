{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TupleSections     #-}
{-# LANGUAGE TypeFamilies      #-}
{-# LANGUAGE ViewPatterns      #-}

module Ide.Plugin.Hlint
  (
    descriptor
  --, provider 
  ) where

-- import DA.Daml.DocTest
-- import Development.IDE.Core.Service.Daml
-- import qualified DA.Daml.LF.Ast as LF
-- import qualified DA.Daml.LF.ScenarioServiceClient as SS
-- import Control.Exception.Safe
-- import Development.IDE.Core.RuleTypes.Daml
-- import Development.IDE.Core.Rules
-- import Development.IDE.Core.Service.Daml
-- import Development.IDE.Types.Location
-- import qualified DA.Daml.LF.Ast as LF
-- import qualified DA.Daml.Visual as Visual
-- import qualified Data.NameMap as NM
import Control.DeepSeq
import Control.Exception
import Control.Monad
import Control.Monad.Extra
import Control.Monad.Trans.Maybe
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (toJSON, fromJSON, Value(..), Result(..))
import Data.Binary
import qualified Data.ByteString as BS
import Data.Either.Extra
import Data.Foldable
import Data.Functor
import qualified Data.HashMap.Strict as Map
import Data.Hashable
import Data.List
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe
import qualified Data.Set as Set
import Data.Set (Set)
import qualified Data.Text as T
import Data.Typeable
import Data.Typeable (Typeable)
import Development.IDE.Core.OfInterest
import Development.IDE.Core.RuleTypes
import Development.IDE.Core.Rules
import Development.IDE.Core.Service
import Development.IDE.Core.Shake
import Development.IDE.LSP.Server
import Development.IDE.Plugin
import Development.IDE.Types.Diagnostics as D
import Development.IDE.Types.Location
import Development.IDE.Types.Logger
import Development.Shake
-- import Development.Shake hiding ( Diagnostic )
import GHC
import GHC.Generics
import GHC.Generics (Generic)
import HscTypes (ModIface, ModSummary)
import Ide.Types
import qualified Language.Haskell.Exts.SrcLoc as HSE
import Language.Haskell.HLint
import Language.Haskell.HLint as Hlint
import qualified Language.Haskell.LSP.Core as LSP
import Language.Haskell.LSP.Messages
import Language.Haskell.LSP.Types
import qualified Language.Haskell.LSP.Types      as LSP
import qualified Language.Haskell.LSP.Types.Lens as LSP
import System.Directory
import System.Directory.Extra as Dir
import System.Environment.Blank
import System.FilePath
import System.IO.Error
import Text.Regex.TDFA.Text()


-- import "ghc-lib-parser" Module (UnitId)
-- ---------------------------------------------------------------------

descriptor :: PluginId -> PluginDescriptor
descriptor plId = (defaultPluginDescriptor plId)
  { pluginRules = rules
--  , pluginCommands =
--      [ PluginCommand "applyOne" "Apply a single hint" applyOneCmd
--      , PluginCommand "applyAll" "Apply all hints to the file" applyAllCmd
--      ]
--  , pluginCodeActionProvider = Just codeActionProvider
  }

data GetHlintDiagnostics = GetHlintDiagnostics
    deriving (Eq, Show, Typeable, Generic)
instance Hashable GetHlintDiagnostics
instance NFData   GetHlintDiagnostics
instance Binary   GetHlintDiagnostics

type instance RuleResult GetHlintDiagnostics = ()

rules :: Rules ()
rules = do
  define $ \GetHlintDiagnostics file -> do
    pm <- use_ GetParsedModule file
    let anns = pm_annotations pm
    let modu = pm_parsed_source pm
    (classify, hint) <- useNoFile_ GetHlintSettings
    let ideas = applyHints classify hint [createModuleEx anns modu]
    return ([diagnostic file i | i <- ideas, ideaSeverity i /= Ignore], Just ())

  action $ do
    files <- getFilesOfInterest
    void $ uses GetHlintDiagnostics $ Set.toList files

  where
      srcSpanToRange :: HSE.SrcSpan -> LSP.Range
      srcSpanToRange span = Range {
          _start = LSP.Position {
                _line = HSE.srcSpanStartLine span - 1
              , _character  = HSE.srcSpanStartColumn span - 1}
        , _end   = LSP.Position {
                _line = HSE.srcSpanEndLine span - 1
             , _character = HSE.srcSpanEndColumn span - 1}
        }
      diagnostic :: NormalizedFilePath -> Idea -> FileDiagnostic
      diagnostic file i =
        (file, ShowDiag, LSP.Diagnostic {
              _range = srcSpanToRange $ ideaSpan i
            , _severity = Just LSP.DsInfo
            , _code = Nothing
            , _source = Just "hlint"
            , _message = T.pack $ show i
            , _relatedInformation = Nothing
      })

-- ---------------------------------------------------------------------

data HlintUsage
  = HlintEnabled { hlintUseDataDir :: FilePath, hlintAllowOverrides :: Bool }
  | HlintDisabled
  deriving Show

data GetHlintSettings = GetHlintSettings
    deriving (Eq, Show, Typeable, Generic)
instance Hashable GetHlintSettings
instance NFData   GetHlintSettings
instance NFData Hint where rnf = rwhnf
instance NFData Classify where rnf = rwhnf
instance Show Hint where show = const "<hint>"
instance Binary GetHlintSettings

type instance RuleResult GetHlintSettings = ([Classify], Hint)

getHlintSettingsRule :: HlintUsage -> Rules ()
getHlintSettingsRule usage =
    defineNoFile $ \GetHlintSettings ->
      liftIO $ case usage of
          HlintEnabled dir enableOverrides -> hlintSettings dir enableOverrides
          HlintDisabled -> fail "hlint configuration unspecified"

hlintSettings :: FilePath -> Bool -> IO ([Classify], Hint)
hlintSettings hlintDataDir enableOverrides = do
    curdir <- getCurrentDirectory
    home <- ((:[]) <$> getHomeDirectory) `catchIOError` (const $ return [])
    hlintYaml <- if enableOverrides
        then
          findM Dir.doesFileExist $
          map (</> ".hlint.yaml") (ancestors curdir ++ home)
      else
        return Nothing
    (_, cs, hs) <- foldMapM parseSettings $
      (hlintDataDir </> "hlint.yaml") : maybeToList hlintYaml
    return (cs, hs)
    where
      ancestors = init . map joinPath . reverse . inits . splitPath
      -- `findSettings` calls `readFilesConfig` which in turn calls
      -- `readFileConfigYaml` which finally calls `decodeFileEither` from
      -- the `yaml` library.  Annoyingly that function catches async
      -- exceptions and in particular, it ends up catching
      -- `ThreadKilled`. So, we have to mask to stop it from doing that.
      parseSettings f = mask $ \unmask ->
           findSettings (unmask . const (return (f, Nothing))) (Just f)
      foldMapM f = foldlM (\acc a -> do w <- f a; return $! mappend acc w) mempty

-- ---------------------------------------------------------------------
-- ---------------------------------------------------------------------
-- ---------------------------------------------------------------------
{-
{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings     #-}
-- | apply-refact applies refactorings specified by the refact package. It is
-- currently integrated into hlint to enable the automatic application of
-- suggestions.
module Haskell.Ide.Engine.Plugin.ApplyRefact where

import           Control.Arrow
import           Control.Exception              ( IOException
                                                , ErrorCall
                                                , Handler(..)
                                                , catches
                                                , try
                                                )
import           Control.Lens            hiding ( List )
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Except
import           Data.Aeson                        hiding (Error)
import           Data.Maybe

#if __GLASGOW_HASKELL__ < 808
import           Data.Monoid                       ((<>))
#endif

import qualified Data.Text                         as T
import           GHC.Generics
import           Haskell.Ide.Engine.MonadFunctions
import           Haskell.Ide.Engine.MonadTypes
import           Haskell.Ide.Engine.PluginUtils
import           Language.Haskell.Exts.SrcLoc
import           Language.Haskell.Exts.Parser
import           Language.Haskell.Exts.Extension
import           Language.Haskell.HLint4           as Hlint
import qualified Language.Haskell.LSP.Types        as LSP
import qualified Language.Haskell.LSP.Types.Lens   as LSP
import           Refact.Apply

-- ---------------------------------------------------------------------
{-# ANN module ("HLint: ignore Eta reduce"         :: String) #-}
{-# ANN module ("HLint: ignore Redundant do"       :: String) #-}
{-# ANN module ("HLint: ignore Reduce duplication" :: String) #-}
-- ---------------------------------------------------------------------

type HintTitle = T.Text

applyRefactDescriptor :: PluginId -> PluginDescriptor
applyRefactDescriptor plId = PluginDescriptor
  { pluginId = plId
  , pluginName = "ApplyRefact"
  , pluginDesc = "apply-refact applies refactorings specified by the refact package. It is currently integrated into hlint to enable the automatic application of suggestions."
  , pluginCommands =
      [ PluginCommand "applyOne" "Apply a single hint" applyOneCmd
      , PluginCommand "applyAll" "Apply all hints to the file" applyAllCmd
      ]
  , pluginCodeActionProvider = Just codeActionProvider
  , pluginDiagnosticProvider = Nothing
  , pluginHoverProvider = Nothing
  , pluginSymbolProvider = Nothing
  , pluginFormattingProvider = Nothing
  }

-- ---------------------------------------------------------------------

data ApplyOneParams = AOP
  { file      :: Uri
  , start_pos :: Position
  -- | There can be more than one hint suggested at the same position, so HintTitle is used to distinguish between them.
  , hintTitle :: HintTitle
  } deriving (Eq,Show,Generic,FromJSON,ToJSON)

data OneHint = OneHint
  { oneHintPos :: Position
  , oneHintTitle :: HintTitle
  } deriving (Eq, Show)

applyOneCmd :: ApplyOneParams -> IdeGhcM (IdeResult WorkspaceEdit)
applyOneCmd (AOP uri pos title) = pluginGetFile "applyOne: " uri $ \fp -> do
  let oneHint = OneHint pos title
  revMapp <- reverseFileMap
  let defaultResult = do
        debugm "applyOne: no access to the persisted file."
        return $ IdeResultOk mempty
  withMappedFile fp defaultResult $ \file' -> do
    res <- liftToGhc $ applyHint file' (Just oneHint) revMapp
    logm $ "applyOneCmd:file=" ++ show fp
    logm $ "applyOneCmd:res=" ++ show res
    case res of
      Left err -> return $ IdeResultFail
        (IdeError PluginError (T.pack $ "applyOne: " ++ show err) Null)
      Right fs -> return (IdeResultOk fs)


-- ---------------------------------------------------------------------

applyAllCmd :: Uri -> IdeGhcM (IdeResult WorkspaceEdit)
applyAllCmd uri = pluginGetFile "applyAll: " uri $ \fp -> do
  let defaultResult = do
        debugm "applyAll: no access to the persisted file."
        return $ IdeResultOk mempty
  revMapp <- reverseFileMap
  withMappedFile fp defaultResult $ \file' -> do
    res <- liftToGhc $ applyHint file' Nothing revMapp
    logm $ "applyAllCmd:res=" ++ show res
    case res of
      Left err -> return $ IdeResultFail (IdeError PluginError
                    (T.pack $ "applyAll: " ++ show err) Null)
      Right fs -> return (IdeResultOk fs)

-- ---------------------------------------------------------------------

-- AZ:TODO: Why is this in IdeGhcM?
lint :: Uri -> IdeGhcM (IdeResult PublishDiagnosticsParams)
lint uri = pluginGetFile "lint: " uri $ \fp -> do
  let
    defaultResult = do
      debugm "lint: no access to the persisted file."
      return
        $ IdeResultOk (PublishDiagnosticsParams (filePathToUri fp) $ List [])
  withMappedFile fp defaultResult $ \file' -> do
    eitherErrorResult <- liftIO
      (try $ runExceptT $ runLint file' [] :: IO
          (Either IOException (Either [Diagnostic] [Idea]))
      )
    case eitherErrorResult of
      Left err -> return $ IdeResultFail
        (IdeError PluginError (T.pack $ "lint: " ++ show err) Null)
      Right res -> case res of
        Left diags ->
          return
            (IdeResultOk
              (PublishDiagnosticsParams (filePathToUri fp) $ List diags)
            )
        Right fs ->
          return
            $ IdeResultOk
            $ PublishDiagnosticsParams (filePathToUri fp)
            $ List (map hintToDiagnostic $ stripIgnores fs)

runLint :: FilePath -> [String] -> ExceptT [Diagnostic] IO [Idea]
runLint fp args = do
  (flags,classify,hint) <- liftIO $ argsSettings args
  let myflags = flags { hseFlags = (hseFlags flags) { extensions = EnableExtension TypeApplications:extensions (hseFlags flags)}}
  res <- bimapExceptT parseErrorToDiagnostic id $ ExceptT $ parseModuleEx myflags fp Nothing
  pure $ applyHints classify hint [res]

parseErrorToDiagnostic :: Hlint.ParseError -> [Diagnostic]
parseErrorToDiagnostic (Hlint.ParseError l msg contents) =
  [Diagnostic
      { _range    = srcLoc2Range l
      , _severity = Just DsInfo -- Not displayed
      , _code     = Just (LSP.StringValue "parser")
      , _source   = Just "hlint"
      , _message  = T.unlines [T.pack msg,T.pack contents]
      , _relatedInformation = Nothing
      }]

{-
-- | An idea suggest by a 'Hint'.
data Idea = Idea
    {ideaModule :: String -- ^ The module the idea applies to, may be @\"\"@ if the module cannot be determined or is a result of cross-module hints.
    ,ideaDecl :: String -- ^ The declaration the idea applies to, typically the function name, but may be a type name.
    ,ideaSeverity :: Severity -- ^ The severity of the idea, e.g. 'Warning'.
    ,ideaHint :: String -- ^ The name of the hint that generated the idea, e.g. @\"Use reverse\"@.
    ,ideaSpan :: SrcSpan -- ^ The source code the idea relates to.
    ,ideaFrom :: String -- ^ The contents of the source code the idea relates to.
    ,ideaTo :: Maybe String -- ^ The suggested replacement, or 'Nothing' for no replacement (e.g. on parse errors).
    ,ideaNote :: [Note] -- ^ Notes about the effect of applying the replacement.
    ,ideaRefactoring :: [Refactoring R.SrcSpan] -- ^ How to perform this idea
    }
    deriving (Eq,Ord)

-}

-- | Map over both failure and success.
bimapExceptT :: Functor m => (e -> f) -> (a -> b) -> ExceptT e m a -> ExceptT f m b
bimapExceptT f g (ExceptT m) = ExceptT (fmap h m) where
  h (Left e)  = Left (f e)
  h (Right a) = Right (g a)
{-# INLINE bimapExceptT #-}

-- ---------------------------------------------------------------------

stripIgnores :: [Idea] -> [Idea]
stripIgnores ideas = filter notIgnored ideas
  where
    notIgnored idea = ideaSeverity idea /= Ignore

-- ---------------------------------------------------------------------

hintToDiagnostic :: Idea -> Diagnostic
hintToDiagnostic idea
  = Diagnostic
      { _range    = ss2Range (ideaSpan idea)
      , _severity = Just (hintSeverityMap $ ideaSeverity idea)
      , _code     = Just (LSP.StringValue $ T.pack $ ideaHint idea)
      , _source   = Just "hlint"
      , _message  = idea2Message idea
      , _relatedInformation = Nothing
      }

-- ---------------------------------------------------------------------

idea2Message :: Idea -> T.Text
idea2Message idea = T.unlines $ [T.pack $ ideaHint idea, "Found:", "  " <> T.pack (ideaFrom idea)]
                               <> toIdea <> map (T.pack . show) (ideaNote idea)
  where
    toIdea :: [T.Text]
    toIdea = case ideaTo idea of
      Nothing -> []
      Just i  -> [T.pack "Why not:", T.pack $ "  " ++ i]

-- ---------------------------------------------------------------------
-- | Maps hlint severities to LSP severities
-- | We want to lower the severities so HLint errors and warnings
-- | don't mix with GHC errors and warnings:
-- | as per https://github.com/haskell/haskell-ide-engine/issues/375
hintSeverityMap :: Severity -> DiagnosticSeverity
hintSeverityMap Ignore     = DsInfo -- cannot really happen after stripIgnores
hintSeverityMap Suggestion = DsHint
hintSeverityMap Warning    = DsInfo
hintSeverityMap Error      = DsInfo

-- ---------------------------------------------------------------------

srcLoc2Range :: SrcLoc -> Range
srcLoc2Range (SrcLoc _ l c) = Range ps pe
  where
    ps = Position (l-1) (c-1)
    pe = Position (l-1) 100000

-- ---------------------------------------------------------------------

ss2Range :: SrcSpan -> Range
ss2Range ss = Range ps pe
  where
    ps = Position (srcSpanStartLine ss - 1) (srcSpanStartColumn ss - 1)
    pe = Position (srcSpanEndLine ss - 1)   (srcSpanEndColumn ss - 1)

-- ---------------------------------------------------------------------

applyHint :: FilePath -> Maybe OneHint -> (FilePath -> FilePath) -> IdeM (Either String WorkspaceEdit)
applyHint fp mhint fileMap = do
  runExceptT $ do
    ideas <- getIdeas fp mhint
    let commands = map (show &&& ideaRefactoring) ideas
    liftIO $ logm $ "applyHint:apply=" ++ show commands
    -- set Nothing as "position" for "applyRefactorings" because
    -- applyRefactorings expects the provided position to be _within_ the scope
    -- of each refactoring it will apply.
    -- But "Idea"s returned by HLint pont to starting position of the expressions
    -- that contain refactorings, so they are often outside the refactorings' boundaries.
    -- Example:
    -- Given an expression "hlintTest = reid $ (myid ())"
    -- Hlint returns an idea at the position (1,13)
    -- That contains "Redundant brackets" refactoring at position (1,20):
    --
    -- [("src/App/Test.hs:5:13: Warning: Redundant bracket\nFound:\n  reid $ (myid ())\nWhy not:\n  reid $ myid ()\n",[Replace {rtype = Expr, pos = SrcSpan {startLine = 5, startCol = 20, endLine = 5, endCol = 29}, subts = [("x",SrcSpan {startLine = 5, startCol = 21, endLine = 5, endCol = 28})], orig = "x"}])]
    --
    -- If we provide "applyRefactorings" with "Just (1,13)" then
    -- the "Redundant bracket" hint will never be executed
    -- because SrcSpan (1,20,??,??) doesn't contain position (1,13).
    res <- liftIO $ (Right <$> applyRefactorings Nothing commands fp) `catches`
              [ Handler $ \e -> return (Left (show (e :: IOException)))
              , Handler $ \e -> return (Left (show (e :: ErrorCall)))
              ]
    case res of
      Right appliedFile -> do
        diff <- ExceptT $ Right <$> makeDiffResult fp (T.pack appliedFile) fileMap
        liftIO $ logm $ "applyHint:diff=" ++ show diff
        return diff
      Left err ->
        throwE (show err)

-- | Gets HLint ideas for
getIdeas :: MonadIO m => FilePath -> Maybe OneHint -> ExceptT String m [Idea]
getIdeas lintFile mhint = do
  let hOpts = hlintOpts lintFile (oneHintPos <$> mhint)
  ideas <- runHlint lintFile hOpts
  pure $ maybe ideas (`filterIdeas` ideas) mhint

-- | If we are only interested in applying a particular hint then
-- let's filter out all the irrelevant ideas
filterIdeas :: OneHint -> [Idea] -> [Idea]
filterIdeas (OneHint (Position l c) title) ideas =
  let
    title' = T.unpack title
    ideaPos = (srcSpanStartLine &&& srcSpanStartColumn) . ideaSpan
  in filter (\i -> ideaHint i == title' && ideaPos i == (l+1, c+1)) ideas

hlintOpts :: FilePath -> Maybe Position -> [String]
hlintOpts lintFile mpos =
  let
    posOpt (Position l c) = " --pos " ++ show (l+1) ++ "," ++ show (c+1)
    opts = maybe "" posOpt mpos
  in [lintFile, "--quiet", "--refactor", "--refactor-options=" ++ opts ]

runHlint :: MonadIO m => FilePath -> [String] -> ExceptT String m [Idea]
runHlint fp args =
  do (flags,classify,hint) <- liftIO $ argsSettings args
     let myflags = flags { hseFlags = (hseFlags flags) { extensions = EnableExtension TypeApplications:extensions (hseFlags flags)}}
     res <- bimapExceptT showParseError id $ ExceptT $ liftIO $ parseModuleEx myflags fp Nothing
     pure $ applyHints classify hint [res]

showParseError :: Hlint.ParseError -> String
showParseError (Hlint.ParseError location message content) =
  unlines [show location, message, content]

-- ---------------------------------------------------------------------

codeActionProvider :: CodeActionProvider
codeActionProvider plId docId _ context = IdeResultOk <$> hlintActions
  where

    hlintActions :: IdeM [LSP.CodeAction]
    hlintActions = catMaybes <$> mapM mkHlintAction (filter validCommand diags)

    -- |Some hints do not have an associated refactoring
    validCommand (LSP.Diagnostic _ _ (Just (LSP.StringValue code)) (Just "hlint") _ _) =
      case code of
        "Eta reduce" -> False
        _            -> True
    validCommand _ = False

    LSP.List diags = context ^. LSP.diagnostics

    mkHlintAction :: LSP.Diagnostic -> IdeM (Maybe LSP.CodeAction)
    mkHlintAction diag@(LSP.Diagnostic (LSP.Range start _) _s (Just (LSP.StringValue code)) (Just "hlint") m _) =
      Just . codeAction <$> mkLspCommand plId "applyOne" title (Just args)
     where
       codeAction cmd = LSP.CodeAction title (Just LSP.CodeActionQuickFix) (Just (LSP.List [diag])) Nothing (Just cmd)
       title = "Apply hint:" <> head (T.lines m)
       -- need 'file', 'start_pos' and hint title (to distinguish between alternative suggestions at the same location)
       args = [toJSON (AOP (docId ^. LSP.uri) start code)]
    mkHlintAction (LSP.Diagnostic _r _s _c _source _m _) = return Nothing
-}
