{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE BangPatterns               #-}

module Data.KeyStore.KS.Crypto
  ( sizeAesIV
  , sizeOAE
  , defaultEncryptedCopyKS
  , saveKS
  , restoreKS
  , mkAESKeyKS
  , encryptKS
  , decryptKS
  , decryptE
  , encodeRSASecretData
  , decodeRSASecretData
  , decodeRSASecretData_
  , encryptRSAKS
  , decryptRSAKS
  , decryptRSAE
  , oaep
  , signKS
  , verifyKS
  , pssp
  , encryptAESKS
  , encryptAES
  , decryptAES
  , randomAESKeyKS
  , randomIVKS
  , hashKS
  , defaultHashParams
  , defaultHashParamsKS
  , hashKS_
  , generateKeysKS
  , generateKeysKS_
  , decodePrivateKeyDERE
  , decodePublicKeyDERE
  , encodePrivateKeyDER
  , encodePublicKeyDER
  , decodeDERE
  , encodeDER
  -- testing
  , test_crypto
  ) where


import           Data.KeyStore.KS.KS
import           Data.KeyStore.KS.Opt
import           Data.KeyStore.Types
import           Data.API.Types
import qualified Data.ASN1.Encoding             as A
import qualified Data.ASN1.BinaryEncoding       as A
import qualified Data.ASN1.Types                as A
import qualified Data.ByteString.Lazy.Char8     as LBS
import qualified Data.ByteString.Char8          as B
import           Control.Applicative
import           Crypto.PubKey.RSA
import qualified Crypto.PubKey.RSA.OAEP         as OAEP
import qualified Crypto.PubKey.RSA.PSS          as PSS
import           Crypto.PubKey.HashDescr
import           Crypto.PubKey.MaskGenFunction
import           Crypto.Cipher.AES


sizeAesIV, sizeOAE :: Octets
sizeAesIV = 16
sizeOAE   = 256


--
-- smoke tests
--

test_crypto :: Bool
test_crypto = test_oaep && test_pss

test_oaep :: Bool
test_oaep = trun $
 do (puk,prk) <- generateKeysKS
    tm'       <- encryptKS puk tm >>= decryptKS prk
    return $ tm' == tm
  where
    tm = ClearText $ Binary "test message"

test_pss :: Bool
test_pss = trun $
 do (puk,prk) <- generateKeysKS
    sig  <- signKS prk tm
    return $ verifyKS puk tm  sig && not (verifyKS puk tm' sig)
  where
    tm  = ClearText $ Binary "hello"
    tm' = ClearText $ Binary "gello"


--
-- defaultEncryptedCopy
--

defaultEncryptedCopyKS :: Safeguard -> KS EncrypedCopy
defaultEncryptedCopyKS sg =
 do ciphr <- lookupOpt opt__crypt_cipher
    prf   <- lookupOpt opt__crypt_prf
    itrns <- lookupOpt opt__crypt_iterations
    st_sz <- lookupOpt opt__crypt_salt_octets
    slt   <- randomBytes st_sz (Salt . Binary)
    return
        EncrypedCopy
            { _ec_safeguard   = sg
            , _ec_cipher      = ciphr
            , _ec_prf         = prf
            , _ec_iterations  = itrns
            , _ec_salt        = slt
            , _ec_secret_data = ECD_no_data void_
            }


--
-- saving and restoring secret copies
--

saveKS :: EncryptionKey -> ClearText -> KS EncrypedCopyData
saveKS ek ct =
    case ek of
      EK_public    puk -> ECD_rsa   <$> encryptKS puk ct
      EK_private   _   -> errorKS "Crypto.Save: saving with private key"
      EK_symmetric aek -> ECD_aes   <$> encryptAESKS aek ct
      EK_none      _   -> ECD_clear <$> return ct

restoreKS :: EncrypedCopyData -> EncryptionKey -> KS ClearText
restoreKS ecd ek =
    case (ecd,ek) of
      (ECD_rsa     rsd,EK_private   prk) -> decryptKS prk rsd
      (ECD_aes     asd,EK_symmetric aek) -> return $ decryptAES aek asd
      (ECD_clear   ct ,EK_none      _  ) -> return ct
      (ECD_no_data _  ,_               ) -> errorKS "restore: no data!"
      _                                  -> errorKS "unexpected EncrypedCopy/EncryptionKey combo"


--
-- making up an AESKey from a list of source texts
--

mkAESKeyKS :: EncrypedCopy -> [ClearText] -> KS AESKey
mkAESKeyKS _              []  = error "mkAESKey: no texts"
mkAESKeyKS EncrypedCopy{..} cts = p2 <$> lookupOpt opt__crypt_cipher
  where
    p2 ciphr = pbkdf _ec_prf ct _ec_salt _ec_iterations (keyWidth ciphr) $ AESKey . Binary

    ct       = ClearText $ Binary $ B.concat $ map (_Binary._ClearText) cts


--
-- encrypting & decrypting
--

encryptKS :: PublicKey -> ClearText -> KS RSASecretData
encryptKS pk ct =
 do cip <- lookupOpt opt__crypt_cipher
    aek <- randomAESKeyKS cip
    rek <- encryptRSAKS pk aek
    asd <- encryptAESKS aek ct
    return
        RSASecretData
            { _rsd_encrypted_key    = rek
            , _rsd_aes_secret_data = asd
            }

decryptKS :: PrivateKey -> RSASecretData -> KS ClearText
decryptKS pk dat = e2ks $ decryptE pk dat

decryptE :: PrivateKey -> RSASecretData -> E ClearText
decryptE pk RSASecretData{..} =
 do aek <- decryptRSAE pk _rsd_encrypted_key
    return $ decryptAES aek _rsd_aes_secret_data


--
-- Serializing RSASecretData
--

encodeRSASecretData :: RSASecretData -> RSASecretBytes
encodeRSASecretData RSASecretData{..} =
    RSASecretBytes $ Binary $
        B.concat
            [ _Binary $ _RSAEncryptedKey _rsd_encrypted_key
            , _Binary $ _IV              _asd_iv
            , _Binary $ _SecretData      _asd_secret_data
            ]
  where
    AESSecretData{..} = _rsd_aes_secret_data

decodeRSASecretData :: RSASecretBytes -> KS RSASecretData
decodeRSASecretData (RSASecretBytes dat) = e2ks $ decodeRSASecretData_ $ _Binary dat

decodeRSASecretData_ :: B.ByteString -> E RSASecretData
decodeRSASecretData_ dat0 =
 do (eky,dat1) <- slice sizeOAE   dat0
    (iv ,edat) <- slice sizeAesIV dat1
    return
        RSASecretData
            { _rsd_encrypted_key    = RSAEncryptedKey $ Binary eky
            , _rsd_aes_secret_data =
                AESSecretData
                    { _asd_iv           = IV         $ Binary iv
                    , _asd_secret_data  = SecretData $ Binary edat
                    }
            }
  where
    slice sz bs =
        case B.length bs >= _Octets sz of
          True  -> Right $ B.splitAt (_Octets sz) bs
          False -> Left  $ strMsg "decrypt: not enough bytes"


--
-- RSA encrypting & decrypting
--

encryptRSAKS :: PublicKey -> AESKey -> KS RSAEncryptedKey
encryptRSAKS pk (AESKey (Binary dat)) =
    RSAEncryptedKey . Binary <$> randomRSA (\g->OAEP.encrypt g oaep pk dat)

decryptRSAKS :: PrivateKey -> RSAEncryptedKey -> KS AESKey
decryptRSAKS pk rek = either throwKS return $ decryptRSAE pk rek

decryptRSAE :: PrivateKey -> RSAEncryptedKey -> E AESKey
decryptRSAE pk rek =
    rsa2e $ fmap (AESKey . Binary) $
                OAEP.decrypt Nothing oaep pk $ _Binary $ _RSAEncryptedKey rek

oaep :: OAEP.OAEPParams
oaep =
    OAEP.OAEPParams
        { OAEP.oaepHash       = hashFunction hashDescrSHA512
        , OAEP.oaepMaskGenAlg = mgf1
        , OAEP.oaepLabel      = Nothing
        }


--
-- signing & verifying
--

signKS :: PrivateKey -> ClearText -> KS RSASignature
signKS pk dat =
    RSASignature . Binary <$>
          randomRSA (\g->PSS.sign g Nothing pssp pk $ _Binary $ _ClearText dat)

verifyKS :: PublicKey -> ClearText -> RSASignature -> Bool
verifyKS pk (ClearText (Binary dat)) (RSASignature (Binary sig)) = PSS.verify pssp pk dat sig

pssp :: PSS.PSSParams
pssp = PSS.defaultPSSParams $ hashFunction hashDescrSHA512


--
-- AES encrypting/decrypting
--


encryptAESKS :: AESKey -> ClearText -> KS AESSecretData
encryptAESKS aek ct =
 do iv <- randomIVKS
    return $ encryptAES aek iv ct

encryptAES :: AESKey -> IV -> ClearText -> AESSecretData
encryptAES (AESKey (Binary ky)) (IV (Binary iv)) (ClearText (Binary dat)) =
    AESSecretData
        { _asd_iv          = IV $ Binary iv
        , _asd_secret_data = SecretData $ Binary $ encryptCTR (initAES ky) iv dat
        }

decryptAES :: AESKey -> AESSecretData -> ClearText
decryptAES aek AESSecretData{..} =
    ClearText $ Binary $
        encryptCTR (initAES $ _Binary $ _AESKey aek             )
                   (_Binary $ _IV               _asd_iv         )
                   (_Binary $ _SecretData       _asd_secret_data)

randomAESKeyKS :: Cipher -> KS AESKey
randomAESKeyKS cip = randomBytes (keyWidth cip) (AESKey . Binary)

randomIVKS :: KS IV
randomIVKS = randomBytes sizeAesIV (IV . Binary)


--
-- hashing
--


hashKS :: ClearText -> KS Hash
hashKS ct = flip hashKS_ ct <$> defaultHashParamsKS

defaultHashParams :: HashDescription
defaultHashParams = trun defaultHashParamsKS

defaultHashParamsKS :: KS HashDescription
defaultHashParamsKS =
 do h_cmt <- lookupOpt opt__hash_comment
    h_prf <- lookupOpt opt__hash_prf
    itrns <- lookupOpt opt__hash_iterations
    hs_wd <- lookupOpt opt__hash_width_octets
    st_wd <- lookupOpt opt__hash_salt_octets
    st    <- randomBytes st_wd (Salt . Binary)
    return $ hashd h_cmt h_prf itrns hs_wd st_wd st
  where
    hashd  h_cmt h_prf itrns hs_wd st_wd st =
        HashDescription
            { _hashd_comment      = h_cmt
            , _hashd_prf          = h_prf
            , _hashd_iterations   = itrns
            , _hashd_width_octets = hs_wd
            , _hashd_salt_octets  = st_wd
            , _hashd_salt         = st
            }

hashKS_ :: HashDescription -> ClearText -> Hash
hashKS_ hd@HashDescription{..} ct =
    Hash
        { _hash_description = hd
        , _hash_hash        = pbkdf _hashd_prf ct _hashd_salt _hashd_iterations
                                        _hashd_width_octets (HashData . Binary)
        }

--randomSalt :: KS Salt
--randomSalt = randomBytes size_salt Salt

--
-- Generating a private/public key pair
--

default_e :: Integer
default_e = 0x10001

default_key_size :: Int
default_key_size = 2048 `div` 8

generateKeysKS :: KS (PublicKey,PrivateKey)
generateKeysKS = generateKeysKS_ default_key_size

generateKeysKS_ :: Int -> KS (PublicKey,PrivateKey)
generateKeysKS_ ksz = randomKS $ \g->generate g ksz default_e


--
-- Encoding & decoding private & public keys
--

decodePrivateKeyDERE :: ClearText -> E PrivateKey
decodePrivateKeyDERE = decodeDERE . _Binary . _ClearText

decodePublicKeyDERE :: ClearText -> E PublicKey
decodePublicKeyDERE = decodeDERE . _Binary . _ClearText

encodePrivateKeyDER :: PrivateKey -> ClearText
encodePrivateKeyDER = ClearText . Binary . encodeDER

encodePublicKeyDER :: PublicKey -> ClearText
encodePublicKeyDER = ClearText . Binary . encodeDER

decodeDERE :: A.ASN1Object a => B.ByteString -> E a
decodeDERE bs =
    case A.decodeASN1 A.DER $ lzy bs of
      Left err -> Left $ strMsg $ show err
      Right as ->
        case A.fromASN1 as of
          Left err -> Left $ strMsg $ show err
          Right pr ->
            case pr of
              (pk,[]) -> return pk
              _       -> Left $ strMsg "residual data"
  where
    lzy = LBS.pack . B.unpack

encodeDER :: A.ASN1Object a => a -> B.ByteString
encodeDER = egr . A.encodeASN1 A.DER  . flip A.toASN1 []
  where
    egr = B.pack . LBS.unpack



--
-- Helpers
--

rsa2e :: Either Error a -> E a
rsa2e = either (Left . rsaError) Right
