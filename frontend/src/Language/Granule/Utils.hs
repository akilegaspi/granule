{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE ViewPatterns #-}

module Language.Granule.Utils where

import Control.Exception (SomeException, catch, try)
import Control.Monad (when, forM)
import Data.List ((\\), nub)
import Data.Semigroup ((<>))
import Data.Time.Clock (getCurrentTime)
import Data.Time.LocalTime (getTimeZone, utc, utcToLocalTime)
import Debug.Trace (trace, traceM)
import System.IO (hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)
import "Glob" System.FilePath.Glob (glob)

import Language.Granule.Syntax.Span

-- | A result data type to be used pretty much like `Maybe`, but with an explanation as to why
-- no result was returned
data Result a = Some a | None [String]

data Globals =
  Globals
  { debugging :: Bool
  , sourceFilePath :: String
  , noColors :: Bool
  , noEval :: Bool
  , suppressInfos :: Bool
  , suppressErrors :: Bool
  , timestamp :: Bool
  , solverTimeoutMillis :: Integer
  , includePath :: FilePath
  } deriving Show

defaultGlobals :: Globals
defaultGlobals =
    Globals
    { debugging = False
    , sourceFilePath = ""
    , noColors = False
    , noEval = False
    , suppressInfos = False
    , suppressErrors = False
    , timestamp = False
    , solverTimeoutMillis = 5000
    , includePath = "StdLib"
    }

class UserMsg a where
  title :: a -> String
  location :: a -> Maybe Span
  msg :: a -> String -- short for `message`, not `monosodium glutamate`

  location _ = Nothing

mkSpan :: (?globals :: Globals) => (Pos, Pos) -> Span
mkSpan (start, end) = Span start end (sourceFilePath ?globals)

nullSpan :: (?globals :: Globals) => Span
nullSpan = Span (0, 0) (0, 0) (sourceFilePath ?globals)

debugM :: (?globals :: Globals, Applicative f) => String -> String -> f ()
debugM explanation message =
    when (debugging ?globals) $ traceM $
      ((unsafePerformIO getTimeString) <> (bold $ cyan $ "Debug: ") <> explanation <> " \n") <> message <> "\n"

-- | Print to terminal when debugging e.g.:
-- foo x y = x + y `debug` "foo" $ "given " <> show x <> " and " <> show y
debug :: (?globals :: Globals) => a -> String -> a
debug x message =
    if debugging ?globals
      then ((unsafePerformIO getTimeString) <> (bold $ magenta $ "Debug: ") <> message <> "\n")
           `trace` x
      else x

-- | Append a debug message to a string, which will only get printed when debugging
(<?>) :: (?globals :: Globals) => String -> String -> String
infixr 6 <?>
str <?> msg =
    if debugging ?globals
      then str <> (bold $ magenta $ " Debug { ") <> msg <> (bold $ magenta $ " }")
      else str

printErr :: (?globals :: Globals, UserMsg msg) => msg -> IO ()
printErr err = when (not $ suppressErrors ?globals) $ do
    time <- getTimeString
    hPutStrLn stderr $
      time
      <> (bold $ red $ title err <> ": ")
      <> sourceFile <> lineCol <> "\n"
      <> indent (msg err)
      <> "\n"
  where
    sourceFile =
        case location err of -- sourceFilePath ?globals
          Nothing -> ""
          Just (filename -> "") -> ""
          Just (filename -> p)  -> p <> ":"
    lineCol =
        case location err of
          Nothing -> ""
          Just (Span (0,0) (0,0) _) -> ""
          Just (Span (line,col) _ fileName) -> show line <> ":" <> show col <> ":"

printInfo :: (?globals :: Globals) => String -> IO ()
printInfo message =
    when (not $ suppressInfos ?globals) $ do
      time <- getTimeString
      putStrLn $ time <> message

-- backgColor colorCode = txtColor (colorCode + 10)
bold :: (?globals :: Globals) => String -> String
bold = txtColor "1"

black, red, green, yellow, blue, magenta, cyan, white :: (?globals :: Globals) => String -> String
black = txtColor "30"
red = txtColor "31"
green = txtColor "32"
yellow = txtColor "33"
blue = txtColor "34"
magenta = txtColor "35"
cyan = txtColor "36"
white = txtColor "37"

txtColor :: (?globals :: Globals) => String -> String -> String
txtColor colorCode message =
    if noColors ?globals
      then message
      else "\ESC[" <> colorCode <> ";1m" <> message <> reset
  where
    reset = "\ESC[0m"

indent :: String -> String
indent message = "  " <> message

getTimeString :: (?globals :: Globals) => IO String
getTimeString =
    if timestamp ?globals == False then return ""
    else do
      time <- try getCurrentTime
      case time of
        Right time -> do
          timeZone <-
            catch
              (getTimeZone time) $
              \(e :: SomeException) -> do
                debugM "getTimeZone failed" (show e)
                return utc
          let localTime = utcToLocalTime timeZone time
          return $ show localTime <> ": "
        Left (e :: SomeException) -> do
          debugM "getCurrentTime failed" (show e)
          return ""

-- Extracted from the else in  main from Main.hs for use as a generic function
-- where e is some error handler and f is what is done with each file
processFiles :: [FilePath] -> (FilePath -> IO a) -> (FilePath -> IO a) -> IO [[a]]
processFiles globPatterns e f = forM globPatterns $ (\p -> do
    filePaths <- glob p
    case filePaths of
        [] -> (e p) >>= (return.(:[]))
        _ -> forM filePaths f)

lookupMany :: Eq a => a -> [(a, b)] -> [b]
lookupMany _ []                     = []
lookupMany a' ((a, b):xs) | a == a' = b : lookupMany a' xs
lookupMany a' (_:xs)                = lookupMany a' xs

-- | Get set of duplicates in a list.
-- >>> duplicates [1,2,2,3,3,3]
-- [2,3]
duplicates :: Eq a => [a] -> [a]
duplicates xs = nub (xs \\ nub xs)
