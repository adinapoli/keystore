{-# LANGUAGE QuasiQuotes                #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE MultiParamTypeClasses      #-}

module Deploy.HostSectionKey
  ( HostID(..)
  , SectionID(..)
  , KeyID(..)
  , sections
  ) where

import           Data.KeyStore
import qualified Data.Text                      as T
import qualified Data.ByteString.Char8          as B
import qualified Data.ByteString.Lazy.Char8     as LBS
import qualified Text.RawString.QQ              as RS
import           Control.Monad.RWS.Strict
import           Text.Printf


data HostID
    = H_live_eu
    | H_staging_eu
    | H_live_us
    | H_staging_us
    | H_dev
  deriving (Show, Ord, Eq, Bounded, Enum)

data SectionID
  = S_top
  | S_signing
  | S_eu_admin
  | S_eu_deploy
  | S_eu_staging
  | S_us_admin
  | S_us_deploy
  | S_us_staging
  | S_dev
  deriving (Show, Ord, Eq, Bounded, Enum)

dev, staging, deploy, admin :: SectionID -> Bool
dev     = (`elem` [S_dev                    ] )
staging = (`elem` [S_eu_staging,S_us_staging] )
deploy  = (`elem` [S_eu_deploy ,S_us_deploy ] )
admin   = (`elem` [S_eu_admin  ,S_us_admin  ] )

data KeyID
  = K_admin_init_pw
  | K_super_api
  | K_api
  | K_cloudfront
  | K_s3
  | K_mail
  | K_logger
  | K_ssl
    deriving (Show,Eq,Ord,Bounded,Enum)

instance Code HostID where
  encode = drop 2 . show

instance Code SectionID where
  encode = drop 2 . show

instance Code KeyID where
  encode = drop 2 . show

instance Sections HostID SectionID KeyID where
  hostSection      = host_section
  sectionType      = section_type
  superSections    = super_sections
  keyIsHostIndexed = key_is_host_indexed
  keyIsInSection   = key_is_in_section
  getKeyData       = get_key_data
  sectionSettings  = section_settings
  describeKey      = describe_key
  describeSection  = describe_section

sections :: SECTIONS HostID SectionID KeyID
sections = SECTIONS

host_section :: HostID -> SectionID
host_section h =
  case h of
    H_live_eu    -> S_eu_deploy
    H_staging_eu -> S_eu_staging
    H_live_us    -> S_us_deploy
    H_staging_us -> S_us_staging
    H_dev        -> S_dev

section_type :: SectionID -> SectionType
section_type s =
  case s of
    S_top     -> ST_top
    S_signing -> ST_signing
    _         -> ST_keys

super_sections :: SectionID -> [SectionID]
super_sections s =
  case s of
    S_top        -> [                         ]
    S_signing    -> [S_top                    ]
    S_eu_admin   -> [S_top                    ]
    S_eu_deploy  -> [S_eu_admin               ]
    S_eu_staging -> [S_eu_deploy              ]
    S_us_admin   -> [S_top                    ]
    S_us_deploy  -> [S_us_admin               ]
    S_us_staging -> [S_us_deploy              ]
    S_dev        -> [S_eu_staging,S_us_staging]

key_is_host_indexed :: KeyID -> Maybe (HostID->Bool)
key_is_host_indexed k =
  case k of
    K_ssl -> Just is_ssl
    _     -> Nothing

key_is_in_section :: KeyID -> SectionID -> Bool
key_is_in_section k =
  case k of
    K_admin_init_pw -> f [dev,staging       ,admin]
    K_super_api     -> f [dev,staging       ,admin]
    K_api           -> f [dev,staging,deploy      ]
    K_cloudfront    -> f [dev        ,deploy      ]
    K_s3            -> f [dev,staging,deploy      ]
    K_mail          -> f [dev        ,deploy      ]
    K_logger        -> f [dev                     ]
    K_ssl           -> f [dev,staging,deploy      ]
  where
    f = foldr (\p p' s->p s || p' s) (const False)

generation :: String
generation = "first"

get_key_data :: Maybe HostID -> SectionID -> KeyID -> IO KeyData
get_key_data mb_h s k =
  return
    KeyData
      { kd_identity = Identity $ T.pack $ mk "id"
      , kd_comment  = Comment  $ T.pack $ mk "id"
      , kd_secret   =            B.pack $ mk "secret"
      }
  where
    mk tag =
      printf "%s:%s-%s-%s:%s"
        (tag::String          )
        (maybe "*" encode mb_h)
        (encode s             )
        (encode k             )
        generation

section_settings :: Maybe SectionID -> IO Settings
section_settings Nothing  = e2io $ settingsFromBytes ourSettings
section_settings (Just _) = return mempty

ourSettings :: LBS.ByteString
ourSettings = [RS.r|
{ "debug.enabled"    : true
, "verify.enabled"   : true
, "hash.comment"     : "pbkdf_sha512_20000_64"
, "hash.prf"         : "sha512"
, "hash.iterations"  : 1
, "hash.width_octets": 64
, "hash.salt_octets" : 16
, "crypt.cipher"     : "aes256"
, "crypt.prf"        : "sha512"
, "crypt.iterations" : 1
, "crypt.salt_octets": 16
}
|]

describe_key :: KeyID -> String
describe_key k =
  case k of
    K_admin_init_pw -> "the starting password for the administrator"
    K_super_api     -> "the 'super_api' key will authenticate any request"
    K_api           -> "the api key is needed to make requests when the client has not credentials (e.g., to login)"
    K_cloudfront    -> "the AWS CloudFront signing key"
    K_s3            -> "the AWS S3 access key"
    K_mail          -> "the sendmail access key"
    K_logger        -> "the access key for the logging service"
    K_ssl           -> "the SSL Host key and certificate"

describe_section :: SectionID -> String
describe_section s =
  case s of
    S_top        -> "the top section has access to all keys"
    S_signing    -> "just contains the keystore signing key"
    S_eu_admin   -> "contains adminsitrative keys for the 'eu' live server not required for deployment"
                                                                            ++ "(e.g., the 'super_api' key)"
    S_eu_deploy  -> "has access to all of the keys needed for the 'eu' live server deployment"
    S_eu_staging -> "has access to all of the keys needed for the 'eu' staging server deployment"
    S_us_admin   -> "contains adminsitrative keys for the 'us' live server not required for deployment"
                                                                            ++ "(e.g., the 'super_api' key)"
    S_us_deploy  -> "has access to all of the keys needed for the 'us' live server deployment"
    S_us_staging -> "has access to all of the keys needed for the 'us' staging server deployment"
    S_dev        -> "contains all of the keys needed to deploy a development server"

is_ssl :: HostID -> Bool
is_ssl h =
  case h of
    H_live_eu    -> True
    H_staging_eu -> True
    H_live_us    -> True
    H_staging_us -> True
    H_dev        -> False