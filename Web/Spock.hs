{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Web.Spock
    ( -- * Spock's core functions, types and helpers
      spock, authed, runQuery, getState, Http.StdMethod (..), SpockM, SpockAction
    , authedUser, unauthCurrent, StorageLayer (..), PoolCfg (..)
    , setCookie, getCookie
      -- * Reexports from scotty
    , middleware, get, post, put, delete, patch, addroute, matchAny, notFound
    , request, reqHeader, body, param, params, jsonData, files
    , status, addHeader, setHeader, redirect
    , text, html, file, json, source, raw
    , raise, rescue, next
    )
where

import Web.Spock.SessionManager
import Web.Spock.Monad
import Web.Spock.Types
import Web.Spock.Cookie

import Control.Applicative
import Control.Monad.Trans
import Control.Monad.Trans.Reader
import Control.Monad.Trans.Resource
import Data.Pool
import Data.Time.Clock
import Web.Scotty.Trans
import qualified Data.Text as T
import qualified Network.HTTP.Types as Http

data PoolCfg
   = PoolCfg
   { pc_stripeCount :: Int
   , pc_keepOpenSec :: NominalDiffTime
   , pc_resPerStripe :: Int
   }
   deriving (Show, Eq)

-- | Run a spock application using the warp server, a given db storageLayer and an initial state
spock :: Int -> PoolCfg -> StorageLayer conn -> st -> SpockM conn sess st () -> IO ()
spock port pc storageLayer initialState defs =
    do sessionMgr <- openSessionManager
       connectionPool <- createPool (sl_createConn storageLayer)
                         (sl_closeConn storageLayer) (pc_stripeCount pc)
                         (pc_keepOpenSec pc) (pc_resPerStripe pc)
       let internalState =
               WebState
               { web_dbConn = connectionPool
               , web_sessionMgr = sessionMgr
               , web_state = initialState
               }
           runM m = runResourceT $ runReaderT (runWebStateM m) internalState
           runActionToIO = runM

       scottyT port runM runActionToIO defs

-- | After checking that a login was successfull, register the usersId
-- into the session and create a session cookie for later "authed" requests
-- to work properly
authedUser :: user -> (user -> sess) -> SpockAction conn sess st ()
authedUser user getSessionId =
    do mgr <- getSessMgr
       (sm_createCookieSession mgr) (getSessionId user)

-- | Destroy the current users session
unauthCurrent :: SpockAction conn sess st ()
unauthCurrent =
    do mgr <- getSessMgr
       mSess <- sm_sessionFromCookie mgr
       case mSess of
         Just sess -> liftIO $ (sm_deleteSession mgr) (sess_id sess)
         Nothing -> return ()

-- | Before the request is performed, you can check if the signed in user has permissions to
-- view the contents of the request. You may want to define a helper function that
-- proxies this function to not pass around loadUser and checkRights all the time
authed :: Http.StdMethod -> [T.Text] -> RoutePattern
       -> (conn -> sess -> IO (Maybe user))
       -> (conn -> user -> [T.Text] -> IO Bool)
       -> (user -> SpockAction conn sess st ())
       -> SpockM conn sess st ()
authed reqTy requiredRights route loadUser checkRights action =
    addroute reqTy route $
        do mgr <- getSessMgr
           mSess <- fmap sess_data <$> (sm_sessionFromCookie mgr)
           case mSess of
             Just sval ->
                 do mUser <- runQuery $ \conn -> loadUser conn sval
                    case mUser of
                      Just user ->
                          do isOk <- runQuery $ \conn -> checkRights conn user requiredRights
                             if isOk
                             then action user
                             else http403 "No rights to see this!"
                      Nothing -> http403 "Not logged in"
             Nothing -> http403 "Not logged in"
    where
      http403 msg =
          do status Http.status403
             text msg