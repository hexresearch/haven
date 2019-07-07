{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main where

import Control.Applicative
import Control.Monad
import Control.Monad.Reader
import Control.Monad.Trans.Maybe
import Control.Monad.Writer hiding ((<>))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Char
import Data.Digest.Pure.SHA
import Data.Foldable
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe
import Data.Semigroup
import qualified Data.Set as Set
import Data.Traversable
import Network.HTTP.Conduit hiding (path)
import Network.HTTP.Types.Status
import System.Directory
import System.Environment
import System.Exit
import System.FilePath
import System.IO
import System.IO.Temp
import System.Process
import Text.XML.Light

import Debug.Trace

data HavenEnv = HavenEnv
  { _havenEnv_manager :: Manager
  , _havenEnv_repos :: Map String String
  , _havenEnv_m2Local :: FilePath
  }

-- | Takes multiple maven package descriptions as command line arguments
-- and finds the dependencies of those maven packages.
-- Package descriptions should be of the form @groupid:artifactid:version@
main :: IO ()
main = do
  mgr <- newManager tlsManagerSettings
  [pomXml] <- getArgs
  Just repos <- fmap parseRepos . parseXMLDoc <$> BS.readFile pomXml

  withSystemTempFile "out.txt" $ \tmpFile hTmpFile -> withSystemTempDirectory "m2" $ \m2Repo -> do
    let havenEnv = HavenEnv mgr repos m2Repo
    hProc <- runProcess
      "mvn"
      ["-f", pomXml, "dependency:tree", "-Dverbose", "-DoutputFile=" <> tmpFile, "-Dmaven.repo.local=" <> m2Repo]
      Nothing
      Nothing
      Nothing
      (Just stderr)
      Nothing
    ExitSuccess <- waitForProcess hProc

    _ <- hGetLine hTmpFile -- skip local package name
    (_, mavenNixs) <- runWriterT $ fix $ \loop -> do
      e <- liftIO $ hIsEOF hTmpFile
      unless e $ do
        line <- liftIO $ hGetLine hTmpFile
        traceM line
        let mavenGrArTyVr = dropWhile (not . isAlphaNum) line -- Skip leading symbols; we don't care about parsing this
            (groupId, ':':mavenArTyVr) = break (==':') mavenGrArTyVr
            (artifactId, ':':mavenTyVr) = break (==':') mavenArTyVr
            (fileType, ':':mavenClVr) = break (==':') mavenTyVr -- File type that Maven has decided on
            (clOrVr, ':':mver) = break (==':') mavenClVr
            (classifier, version) = if takeWhile (/=':') mver == mver
              then (Nothing, clOrVr)
              else (Just clOrVr, takeWhile (/=':') mver)
            maven = Maven groupId artifactId version classifier
        unless (all isSpace line) $ do
          mMvnNix <- runReaderT (runMaybeT $ fetch fileType maven) havenEnv
          case mMvnNix of
            Just mvnNix -> tell $ Set.fromList mvnNix
            Nothing -> liftIO $ do
              hPutStrLn stderr $ "Failed for " <> unlines [show fileType, show maven]
              exitFailure
          loop
    putStrLn "["
    traverse_ (putStrLn . toNix) mavenNixs
    putStrLn "]"

parseRepos :: Element -> Map String String
parseRepos pom = Map.fromList $ do
  repoList <- findChildrenByTagName "repositories" pom
  repo <- findChildrenByTagName "repository" repoList
  repoId <- findChildrenByTagName "id" repo
  repoUrl <- findChildrenByTagName "url" repo
  return (strContent repoId, strContent repoUrl)

data Maven = Maven
  { _maven_groupId :: String
  , _maven_artifactId :: String
  , _maven_version :: String
  , _maven_classifier :: Maybe String
  }
  deriving (Show, Read, Eq, Ord)

data MavenNix = MavenNix
  { _mavenNix_maven :: Maven
  , _mavenNix_repo :: String
  , _mavenNix_classifier :: Maybe String
  , _mavenNix_jarSha256 :: Maybe (Digest SHA256State)
  , _mavenNix_pomSha256 :: Maybe (Digest SHA256State)
  , _mavenNix_aarSha256 :: Maybe (Digest SHA256State)
  }
  deriving (Show, Eq, Ord)

-- | Create a nix record for a hashed maven package
toNix :: MavenNix -> String
toNix m =
  let mvn = _mavenNix_maven m
      showHash h = fromMaybe "null" $ (\x -> "\"" <> x <> "\"") . showDigest <$> h
  in unlines $
      [ "  { artifactId = \"" <> _maven_artifactId mvn <> "\";"
      , "    groupId = \"" <> _maven_groupId mvn <> "\";"
      , "    version = \"" <> _maven_version mvn <> "\";"
      , "    repo = \"" <> _mavenNix_repo m <> "\";"
      , "    jarSha256 = " <> showHash (_mavenNix_jarSha256 m) <> ";"
      , "    pomSha256 = " <> showHash (_mavenNix_pomSha256 m) <> ";"
      , "    aarSha256 = " <> showHash (_mavenNix_aarSha256 m) <> ";"
      ] ++ maybe [] (\v -> [
        "    classifier = \"" <> v <> "\";"
      ]) (_maven_classifier mvn)
      ++ ["  }"]

-- | Gets the repo with the given id, calling 'empty' when it's not present
getRepo :: (MonadReader HavenEnv m, MonadPlus m) => String -> m String
getRepo repoId = do
  repos <- asks _havenEnv_repos
  maybe empty pure $ Map.lookup repoId repos

m2Directory :: Maven -> String
m2Directory mvn = foldl (</>) ""
  [ (\x -> if x == '.' then '/' else x) <$> _maven_groupId mvn
  , _maven_artifactId mvn
  , _maven_version mvn -- ++ maybe "" ("-" <>) (_maven_classifier mvn)
  ]


-- | Gets a given artifact for a 'Maven' and hashes it. It will first
-- check the local m2 dir, and then it will try to download it from
-- the online repo. If both fail, an error is logged to 'stderr', and
-- 'empty' is called.
getArtifactFile
  :: (MonadIO m, MonadPlus m, MonadReader HavenEnv m)
  => Maven
  -> String
  -> String
  -> m BL.ByteString
getArtifactFile mvn ext repo = do
  mgr <- asks _havenEnv_manager
  m2Repo <- asks _havenEnv_m2Local
  let m2Dir = m2Directory mvn
      classPostfix = if ext == ".pom" then "" else maybe "" ("-" <>) (_maven_classifier mvn)
      m2Filename = _maven_artifactId mvn <> "-" <> _maven_version mvn <> classPostfix <> ext
      path = m2Repo </> m2Dir </> m2Filename
  m2ArtifactExists <- liftIO $ doesFileExist path
  if m2ArtifactExists then liftIO (BL.readFile path) else do
    let url = repo </> m2Dir </> m2Filename
    req <- liftIO $ parseRequest url
    liftIO $ hPutStrLn stderr $ "Getting URL: " <> url
    rsp <- liftIO $ httpLbs req mgr
    when (responseStatus rsp /= status200) $ do
      liftIO $ hPutStrLn stderr $ "Failed to get URL: " <> url
      empty
    return $ responseBody rsp

-- | Hash a particular maven package's .pom and .jar files and parse the .pom file as xml
fetch
  :: (MonadIO m, MonadReader HavenEnv m)
  => String
  -> Maven
  -> MaybeT m [MavenNix]
fetch fileType mvn = do
  m2Repo <- asks _havenEnv_m2Local
  let m2Dir = m2Repo </> m2Directory mvn
      findRepoId = takeWhile (/='=') . drop 1 . dropWhile (/='>')

  repoId <- findRepoId <$> liftIO (readFile (m2Dir </> "_remote.repositories"))
  repo <- getRepo repoId

  pom <- runMaybeT $ getArtifactFile mvn ".pom" repo

  let noArtifacts = MavenNix
        { _mavenNix_maven = mvn
        , _mavenNix_repo = repo
        , _mavenNix_classifier = _maven_classifier mvn
        , _mavenNix_jarSha256 = Nothing
        , _mavenNix_pomSha256 = sha256 <$> pom
        , _mavenNix_aarSha256 = Nothing
        }

  parents <- fmap (fromMaybe []) $ for pom $ \pomContents -> do
    pomEl <- maybe empty pure $ parseXMLDoc pomContents
    fmap mconcat $ traverse (fetch "pom") $ do
      parent <- findChildrenByTagName "parent" pomEl
      groupId <- strContent <$> findChildrenByTagName "groupId" parent
      artifactId <- strContent <$> findChildrenByTagName "artifactId" parent
      version <- strContent <$> findChildrenByTagName "version" parent
      let classifier = headMay $ strContent <$> findChildrenByTagName "classifier" parent
      return $ Maven groupId artifactId version classifier

  -- TODO: Match the 'type' to the correct file extension.
  -- The extension is _usually_ equal to the type, but it's not necessarily.
  -- See: https://maven.apache.org/pom.html#Dependencies
  mavenNix <- asum
    [ do
      guard (fileType == "jar")
      jarSha <- sha256 <$> getArtifactFile mvn ".jar" repo
      return $ noArtifacts { _mavenNix_jarSha256 = Just jarSha }
    , do
      guard (fileType == "aar")
      aarSha <- sha256 <$> getArtifactFile mvn ".aar" repo
      return $ noArtifacts { _mavenNix_aarSha256 = Just aarSha }
    , do
      guard (fileType == "pom") -- This is used when getting parents
      return noArtifacts
    ]
  return (mavenNix:parents)

headMay :: [a] -> Maybe a
headMay [] = Nothing
headMay (x:_) = Just x

-- | Retrieve an XML Element's children by tag name
findChildrenByTagName :: String -> Element -> [Element]
findChildrenByTagName n = filterChildren (\a -> qName (elName a) == n)

firstChildByTagName :: String -> Element -> Maybe Element
firstChildByTagName n = listToMaybe . findChildrenByTagName n
