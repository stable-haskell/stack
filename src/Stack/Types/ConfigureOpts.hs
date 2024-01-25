{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE NoFieldSelectors    #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings   #-}

module Stack.Types.ConfigureOpts
  ( ConfigureOpts (..)
  , BaseConfigOpts (..)
  , configureOpts
  , configureOptsPathRelated
  , configureOptsNonPathRelated
  ) where

import qualified Data.Map as Map
import qualified Data.Text as T
import           Distribution.Types.MungedPackageName
                   ( decodeCompatPackageName )
import           Distribution.Types.PackageName ( unPackageName )
import           Distribution.Types.UnqualComponentName
                   ( unUnqualComponentName )
import qualified Distribution.Version as C
import           Path ( (</>), parseRelDir )
import           Path.Extra ( toFilePathNoTrailingSep )
import           Stack.Constants
                   ( bindirSuffix, compilerOptionsCabalFlag, docDirSuffix
                   , relDirEtc, relDirLib, relDirLibexec, relDirShare
                   )
import           Stack.Prelude
import           Stack.Types.BuildOpts ( BuildOpts (..) )
import           Stack.Types.BuildOptsCLI ( BuildOptsCLI )
import           Stack.Types.Compiler ( getGhcVersion, whichCompiler )
import           Stack.Types.Config
                   ( Config (..), HasConfig (..) )
import           Stack.Types.EnvConfig ( EnvConfig, actualCompilerVersionL )
import           Stack.Types.GhcPkgId ( GhcPkgId, ghcPkgIdString )
import           Stack.Types.IsMutable ( IsMutable (..) )
import           Stack.Types.Package ( Package (..) )
import           System.FilePath ( pathSeparator )

-- | Basic information used to calculate what the configure options are
data BaseConfigOpts = BaseConfigOpts
  { snapDB :: !(Path Abs Dir)
  , localDB :: !(Path Abs Dir)
  , snapInstallRoot :: !(Path Abs Dir)
  , localInstallRoot :: !(Path Abs Dir)
  , buildOpts :: !BuildOpts
  , buildOptsCLI :: !BuildOptsCLI
  , extraDBs :: ![Path Abs Dir]
  }
  deriving Show

-- | Render a @BaseConfigOpts@ to an actual list of options
configureOpts ::
     EnvConfig
  -> BaseConfigOpts
  -> Map PackageIdentifier GhcPkgId -- ^ dependencies
  -> Bool -- ^ local non-extra-dep?
  -> IsMutable
  -> Package
  -> ConfigureOpts
configureOpts econfig bco deps isLocal isMutable package = ConfigureOpts
  { pathRelated = configureOptsPathRelated bco isMutable package
  , nonPathRelated =
      configureOptsNonPathRelated econfig bco deps isLocal package
  }

configureOptsPathRelated ::
     BaseConfigOpts
  -> IsMutable
  -> Package
  -> [String]
configureOptsPathRelated bco isMutable package = concat
  [ ["--user", "--package-db=clear", "--package-db=global"]
  , map (("--package-db=" ++) . toFilePathNoTrailingSep) $ case isMutable of
      Immutable -> bco.extraDBs ++ [bco.snapDB]
      Mutable -> bco.extraDBs ++ [bco.snapDB] ++ [bco.localDB]
  , [ "--libdir=" ++ toFilePathNoTrailingSep (installRoot </> relDirLib)
    , "--bindir=" ++ toFilePathNoTrailingSep (installRoot </> bindirSuffix)
    , "--datadir=" ++ toFilePathNoTrailingSep (installRoot </> relDirShare)
    , "--libexecdir=" ++ toFilePathNoTrailingSep (installRoot </> relDirLibexec)
    , "--sysconfdir=" ++ toFilePathNoTrailingSep (installRoot </> relDirEtc)
    , "--docdir=" ++ toFilePathNoTrailingSep docDir
    , "--htmldir=" ++ toFilePathNoTrailingSep docDir
    , "--haddockdir=" ++ toFilePathNoTrailingSep docDir]
  ]
 where
  installRoot =
    case isMutable of
      Immutable -> bco.snapInstallRoot
      Mutable -> bco.localInstallRoot
  docDir =
    case pkgVerDir of
      Nothing -> installRoot </> docDirSuffix
      Just dir -> installRoot </> docDirSuffix </> dir
  pkgVerDir = parseRelDir
    (  packageIdentifierString
        (PackageIdentifier package.name package.version)
    ++ [pathSeparator]
    )

-- | Same as 'configureOpts', but does not include directory path options
configureOptsNonPathRelated ::
     EnvConfig
  -> BaseConfigOpts
  -> Map PackageIdentifier GhcPkgId -- ^ Dependencies.
  -> Bool -- ^ Is this a local, non-extra-dep?
  -> Package
  -> [String]
configureOptsNonPathRelated econfig bco deps isLocal package = concat
  [ depOptions
  , [ "--enable-library-profiling"
    | bopts.libProfile || bopts.exeProfile
    ]
  , ["--enable-profiling" | bopts.exeProfile && isLocal]
  , ["--enable-split-objs" | bopts.splitObjs]
  , [ "--disable-library-stripping"
    | not $ bopts.libStrip || bopts.exeStrip
    ]
  , ["--disable-executable-stripping" | not bopts.exeStrip && isLocal]
  , map (\(name,enabled) ->
                     "-f" <>
                     (if enabled
                        then ""
                        else "-") <>
                     flagNameString name)
                  (Map.toList flags)
  , map T.unpack package.cabalConfigOpts
  , processGhcOptions package.ghcOptions
  , map ("--extra-include-dirs=" ++) config.extraIncludeDirs
  , map ("--extra-lib-dirs=" ++) config.extraLibDirs
  , maybe
      []
      (\customGcc -> ["--with-gcc=" ++ toFilePath customGcc])
      config.overrideGccPath
  , ["--exact-configuration"]
  , ["--ghc-option=-fhide-source-paths" | hideSourcePaths cv]
  ]
 where
  -- This function parses the GHC options that are providing in the
  -- stack.yaml file. In order to handle RTS arguments correctly, we need
  -- to provide the RTS arguments as a single argument.
  processGhcOptions :: [Text] -> [String]
  processGhcOptions args =
    let (preRtsArgs, mid) = break ("+RTS" ==) args
        (rtsArgs, end) = break ("-RTS" ==) mid
        fullRtsArgs =
          case rtsArgs of
            [] ->
              -- This means that we didn't have any RTS args - no `+RTS` - and
              -- therefore no need for a `-RTS`.
              []
            _ ->
              -- In this case, we have some RTS args. `break` puts the `"-RTS"`
              -- string in the `snd` list, so we want to append it on the end of
              -- `rtsArgs` here.
              --
              -- We're not checking that `-RTS` is the first element of `end`.
              -- This is because the GHC RTS allows you to omit a trailing -RTS
              -- if that's the last of the arguments. This permits a GHC options
              -- in stack.yaml that matches what you might pass directly to GHC.
              [T.unwords $ rtsArgs ++ ["-RTS"]]
        -- We drop the first element from `end`, because it is always either
        -- `"-RTS"` (and we don't want that as a separate argument) or the list
        -- is empty (and `drop _ [] = []`).
        postRtsArgs = drop 1 end
        newArgs = concat [preRtsArgs, fullRtsArgs, postRtsArgs]
    in  concatMap (\x -> [compilerOptionsCabalFlag wc, T.unpack x]) newArgs

  wc = view (actualCompilerVersionL . to whichCompiler) econfig
  cv = view (actualCompilerVersionL . to getGhcVersion) econfig

  hideSourcePaths ghcVersion =
    ghcVersion >= C.mkVersion [8, 2] && config.hideSourcePaths

  config = view configL econfig
  bopts = bco.buildOpts

  -- Unioning atop defaults is needed so that all flags are specified with
  -- --exact-configuration.
  flags = package.flags `Map.union` package.defaultFlags

  depOptions = map toDepOption $ Map.toList deps

  toDepOption (PackageIdentifier name _, gid) = concat
    [ "--dependency="
    , depOptionKey
    , "="
    , ghcPkgIdString gid
    ]
   where
    MungedPackageName subPkgName lib = decodeCompatPackageName name
    depOptionKey = case lib of
      LMainLibName -> unPackageName name
      LSubLibName cn ->
        unPackageName subPkgName <> ":" <> unUnqualComponentName cn

-- | Configure options to be sent to Setup.hs configure.
data ConfigureOpts = ConfigureOpts
  { pathRelated :: ![String]
    -- ^ Options related to various paths. We separate these out since they do
    -- not have an effect on the contents of the compiled binary for checking
    -- if we can use an existing precompiled cache.
  , nonPathRelated :: ![String]
    -- ^ Options other than path-related options.
  }
  deriving (Data, Eq, Generic, Show, Typeable)

instance NFData ConfigureOpts
