{-# LANGUAGE QuasiQuotes                #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeSynonymInstances       #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# OPTIONS_GHC -fno-warn-orphans       #-}


module Data.KeyStore.Types
    ( module Data.KeyStore.Types
    , module Data.KeyStore.Types.NameAndSafeguard
    , module Data.KeyStore.Types.E
    ) where

import           Data.KeyStore.Types.Schema
import           Data.KeyStore.Types.NameAndSafeguard
import           Data.KeyStore.Types.E
import           Data.Aeson
import qualified Data.Map                       as Map
import           Data.Monoid
import qualified Data.Text                      as T
import           Data.List
import           Data.Ord
import           Data.String
import           Data.API.Tools
import           Data.API.Types
import           Data.API.JSON
import qualified Data.ByteString                as B
import qualified Data.HashMap.Strict            as HM
import qualified Data.Vector                    as V
import           Text.Regex
import qualified Crypto.PBKDF.ByteString        as P
import           Crypto.PubKey.RSA (PublicKey(..), PrivateKey(..))


$(generate                         keystoreSchema)


deriving instance Num Iterations
deriving instance Num Octets


data Pattern =
    Pattern
      { _pat_string :: String
      , _pat_regex  :: Regex
      }

instance Eq Pattern where
    (==) pat pat' = _pat_string pat == _pat_string pat'

instance Show Pattern where
    show pat     = "Pattern " ++ show(_pat_string pat) ++ " <regex>"

instance IsString Pattern where
    fromString s =
        Pattern
            { _pat_string = s
            , _pat_regex  = mkRegex s
            }

pattern :: String -> Pattern
pattern = fromString

inj_pattern :: REP__Pattern -> ParserWithErrs Pattern
inj_pattern (REP__Pattern t) =
    return $
        Pattern
            { _pat_string = s
            , _pat_regex  = mkRegex s
            }
  where
    s = T.unpack t

prj_pattern :: Pattern -> REP__Pattern
prj_pattern = REP__Pattern . T.pack . _pat_string


type TriggerMap = Map.Map TriggerID Trigger

inj_trigger_map :: REP__TriggerMap -> ParserWithErrs TriggerMap
inj_trigger_map = map_from_list "TriggerMap" _tmp_map _trg_id _TriggerID

prj_trigger_map :: TriggerMap -> REP__TriggerMap
prj_trigger_map = REP__TriggerMap . Map.elems


newtype Settings = Settings { _Settings :: Object }
    deriving (Eq,Show)

inj_settings :: REP__Settings -> ParserWithErrs Settings
inj_settings REP__Settings { _stgs_json = Object hm}
                = return $ Settings hm
inj_settings _  = fail "object expected for settings"

prj_settings :: Settings -> REP__Settings
prj_settings (Settings hm) = REP__Settings { _stgs_json = Object hm }

defaultSettings :: Settings
defaultSettings = mempty


instance Monoid Settings where
  mempty = Settings HM.empty

  mappend (Settings fm_0) (Settings fm_1) =
              Settings $ HM.unionWith cmb fm_0 fm_1
    where
      cmb v0 v1 =
        case (v0,v1) of
          (Array v_0,Array v_1) -> Array $ v_0 V.++ v_1
          _                   -> marker

checkSettingsCollisions :: Settings -> [SettingID]
checkSettingsCollisions (Settings hm) =
              [ SettingID k | (k,v)<-HM.toList hm, v==marker ]

marker :: Value
marker = String "*** Collision * in * Settings ***"


type KeyMap = Map.Map Name Key

inj_keymap :: REP__KeyMap -> ParserWithErrs KeyMap
inj_keymap (REP__KeyMap as) =
        return $ Map.fromList [ (_nka_name,_nka_key) | NameKeyAssoc{..}<-as ]

prj_keymap :: KeyMap -> REP__KeyMap
prj_keymap mp = REP__KeyMap [ NameKeyAssoc nme key | (nme,key)<-Map.toList mp ]

emptyKeyStore :: Configuration -> KeyStore
emptyKeyStore cfg =
    KeyStore
        { _ks_config = cfg
        , _ks_keymap = emptyKeyMap
        }

emptyKeyMap :: KeyMap
emptyKeyMap = Map.empty


type EncrypedCopyMap = Map.Map Safeguard EncrypedCopy

inj_encrypted_copy_map :: REP__EncrypedCopyMap -> ParserWithErrs EncrypedCopyMap
inj_encrypted_copy_map (REP__EncrypedCopyMap ecs) =
        return $ Map.fromList [ (_ec_safeguard ec,ec) | ec<-ecs ]

prj_encrypted_copy_map :: EncrypedCopyMap -> REP__EncrypedCopyMap
prj_encrypted_copy_map mp = REP__EncrypedCopyMap [ ec | (_,ec)<-Map.toList mp ]

defaultConfiguration :: Settings -> Configuration
defaultConfiguration stgs =
  Configuration
    { _cfg_settings = stgs
    , _cfg_triggers = Map.empty
    }


inj_safeguard :: REP__Safeguard -> ParserWithErrs Safeguard
inj_safeguard = return . safeguard . _sg_names

prj_safeguard :: Safeguard -> REP__Safeguard
prj_safeguard = REP__Safeguard . safeguardKeys


inj_name :: REP__Name -> ParserWithErrs Name
inj_name = e2p . name . T.unpack . _REP__Name

prj_name :: Name -> REP__Name
prj_name = REP__Name . T.pack . _name



inj_PublicKey :: REP__PublicKey -> ParserWithErrs PublicKey
inj_PublicKey REP__PublicKey{..} =
    return
        PublicKey
            { public_size = _puk_size
            , public_n    = _puk_n
            , public_e    = _puk_e
            }

prj_PublicKey :: PublicKey -> REP__PublicKey
prj_PublicKey PublicKey{..} =
    REP__PublicKey
        { _puk_size = public_size
        , _puk_n    = public_n
        , _puk_e    = public_e
        }




inj_PrivateKey :: REP__PrivateKey -> ParserWithErrs PrivateKey
inj_PrivateKey REP__PrivateKey{..} =
    return
        PrivateKey
            { private_pub  = _prk_pub
            , private_d    = _prk_d
            , private_p    = _prk_p
            , private_q    = _prk_q
            , private_dP   = _prk_dP
            , private_dQ   = _prk_dQ
            , private_qinv = _prk_qinv
            }

prj_PrivateKey :: PrivateKey -> REP__PrivateKey
prj_PrivateKey PrivateKey{..} =
    REP__PrivateKey
        { _prk_pub  = private_pub
        , _prk_d    = private_d
        , _prk_p    = private_p
        , _prk_q    = private_q
        , _prk_dP   = private_dP
        , _prk_dQ   = private_dQ
        , _prk_qinv = private_qinv
        }


e2p :: E a -> ParserWithErrs a
e2p = either (fail . showReason) return

data Dirctn
    = Encrypting
    | Decrypting
    deriving (Show)


pbkdf :: HashPRF
      -> ClearText
      -> Salt
      -> Iterations
      -> Octets
      -> (B.ByteString->a)
      -> a
pbkdf hp (ClearText dat) (Salt st) (Iterations k) (Octets wd) c =
                                        c $ fn (_Binary dat) (_Binary st) k wd
  where
    fn = case hp of
           PRF_sha1   -> P.sha1PBKDF2
           PRF_sha256 -> P.sha256PBKDF2
           PRF_sha512 -> P.sha512PBKDF2

keyWidth :: Cipher -> Octets
keyWidth aes =
    case aes of
       CPH_aes128   -> Octets 16
       CPH_aes192   -> Octets 24
       CPH_aes256   -> Octets 32

void_ :: Void
void_ = Void 0

map_from_list :: Ord a
              => String
              -> (c->[b])
              -> (b->a)
              -> (a->T.Text)
              -> c
              -> ParserWithErrs (Map.Map a b)
map_from_list ty xl xf xt c =
    case [ xt $ xf b | b:_:_<-obss ] of
      [] -> return $ Map.fromDistinctAscList ps
      ds -> fail $ ty ++ ": " ++ show ds ++ "duplicated"
  where
    ps        = [ (xf b,b) | [b]<-obss ]

    obss      = groupBy same $ sortBy (comparing xf) $ xl c

    same b b' = comparing xf b b' == EQ


$(generateAPITools keystoreSchema
                   [ enumTool
                   , jsonTool
                   , lensTool
                   ])
