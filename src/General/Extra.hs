{-# LANGUAGE RecordWildCards, GeneralizedNewtypeDeriving, TupleSections #-}

module General.Extra(
    Timestamp(..), getTimestamp, showRelativeTimestamp,
    createDir,
    newCVar, readCVar, modifyCVar, modifyCVar_,
    registerMaster, forkSlave
    ) where

import Data.Time.Clock
import Data.Time.Calendar
import System.Time.Extra
import System.IO.Unsafe
import Data.IORef
import Data.Tuple.Extra
import System.Directory
import Data.Hashable
import System.FilePath
import Control.Monad.Extra
import Control.Concurrent.Extra


data Timestamp = Timestamp UTCTime Int deriving (Show,Eq)

{-# NOINLINE timestamp #-}
timestamp :: IORef Int
timestamp = unsafePerformIO $ newIORef 0

getTimestamp :: IO Timestamp
getTimestamp = do
    t <- getCurrentTime
    i <- atomicModifyIORef timestamp $ dupe . (+1)
    return $ Timestamp t i

showRelativeTimestamp :: IO (Timestamp -> String)
showRelativeTimestamp = do
    now <- getCurrentTime
    return $ \(Timestamp old _) ->
        let secs = subtractTime now old
            days = toModifiedJulianDay . utctDay
            poss = [(days now - days old, "day")
                   ,(floor $ secs / (60*60), "hour")
                   ,(floor $ secs / 60, "min")
                   ,(max 1 $ floor secs, "sec")
                   ]
            (i,s) = head $ dropWhile ((==) 0 . fst) poss
        in show i ++ " " ++ s ++ ['s' | i /= 1] ++ " ago"

createDir :: String -> [String] -> IO FilePath
createDir prefix info = do
    let name = prefix ++ "-" ++ show (abs $ hash info)
    writeFile (name <.> "txt") $ unlines info
    createDirectoryIfMissing True name
    return name


---------------------------------------------------------------------
-- CVAR

-- | A Var, but where readCVar returns the last cached value
data CVar a = CVar {cvarCache :: Var a, cvarReal :: Var a}

newCVar :: a -> IO (CVar a)
newCVar x = liftM2 CVar (newVar x) (newVar x)

readCVar :: CVar a -> IO a
readCVar = readVar . cvarCache

modifyCVar :: CVar a -> (a -> IO (a, b)) -> IO b
modifyCVar CVar{..} f =
    modifyVar cvarReal $ \a -> do
        (a,b) <- f a
        modifyVar_ cvarCache $ const $ return a
        return (a,b)

modifyCVar_ :: CVar a -> (a -> IO a) -> IO ()
modifyCVar_ cvar f = modifyCVar cvar $ fmap (,()) . f


---------------------------------------------------------------------
-- SLAVE/MASTER

{-# NOINLINE master #-}
master :: IORef (Maybe ThreadId)
master = unsafePerformIO $ newIORef Nothing

registerMaster :: IO ()
registerMaster = writeIORef master . Just =<< myThreadId

forkSlave :: IO () -> IO ()
forkSlave act = void $ forkFinally act $ \v -> case v of
    Left e -> do
        m <- readIORef master
        whenJust m $ flip throwTo e
    _ -> return ()