{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
module Network.Haskoin.Transaction.Types
    ( Tx(..)
    , TxIn(..)
    , TxOut(..)
    , OutPoint(..)
    , TxHash(..)
    , txHash
    , hexToTxHash
    , txHashToHex
    , nosigTxHash
    , nullOutPoint
    , genesisTx
    ) where

import           Control.Applicative           ((<|>))
import           Control.DeepSeq               (NFData, rnf)
import           Control.Monad                 (forM_, guard, liftM2, mzero,
                                                replicateM, (<=<))
import           Data.Aeson                    (FromJSON, ToJSON,
                                                Value (String), parseJSON,
                                                toJSON, withText)
import           Data.ByteString               (ByteString)
import qualified Data.ByteString               as BS
import           Data.Hashable                 (Hashable)
import           Data.Maybe                    (fromMaybe, maybe)
import           Data.Serialize                (Serialize, decode, encode, get,
                                                put)
import           Data.Serialize.Get
import           Data.Serialize.Put
import           Data.String                   (IsString, fromString)
import           Data.String.Conversions       (cs)
import           Data.Word                     (Word32, Word64)
import           Network.Haskoin.Crypto.Hash
import           Network.Haskoin.Network.Types
import           Network.Haskoin.Script.Types
import           Network.Haskoin.Util
import qualified Text.Read                     as R

newtype TxHash = TxHash { getTxHash :: Hash256 }
    deriving (Eq, Ord, NFData, Hashable, Serialize)

instance Show TxHash where
    showsPrec d a =
        showParen (d > 10) $ showString "TxHash " . shows (txHashToHex a)

instance Read TxHash where
    readPrec = R.parens $ do
        R.Ident "TxHash" <- R.lexP
        R.String str <- R.lexP
        maybe R.pfail return $ hexToTxHash $ cs str

instance IsString TxHash where
    fromString s =
        let e = error "Could not read transaction hash from hex string"
        in fromMaybe e $ hexToTxHash $ cs s

instance FromJSON TxHash where
    parseJSON = withText "Transaction id" $ \t ->
        maybe mzero return $ hexToTxHash $ cs t

instance ToJSON TxHash where
    toJSON = String . cs . txHashToHex

nosigTxHash :: Tx -> TxHash
nosigTxHash tx =
    TxHash $ doubleSHA256 $ encode tx { txIn = map clearInput $ txIn tx }
  where
    clearInput ti = ti { scriptInput = BS.empty }

txHashToHex :: TxHash -> ByteString
txHashToHex (TxHash h) = encodeHex (BS.reverse (encode h))

hexToTxHash :: ByteString -> Maybe TxHash
hexToTxHash hex = do
    bs <- BS.reverse <$> decodeHex hex
    h <- either (const Nothing) Just (decode bs)
    return $ TxHash h

type WitnessData = [WitnessStack]
type WitnessStack = [WitnessStackItem]
type WitnessStackItem = ByteString

-- | Data type representing a bitcoin transaction
data Tx = Tx
    { -- | Transaction data format version
      txVersion  :: !Word32
      -- | List of transaction inputs
    , txIn       :: ![TxIn]
      -- | List of transaction outputs
    , txOut      :: ![TxOut]
      -- | The witness data for the transaction
    , txWitness  :: !WitnessData
      -- | The block number or timestamp at which this transaction is locked
    , txLockTime :: !Word32
    } deriving (Eq, Ord)

txHash :: Tx -> TxHash
txHash tx = TxHash (doubleSHA256 (encode tx {txWitness = []}))

instance Show Tx where
    show = show . encodeHex . encode

instance IsString Tx where
    fromString =
        fromMaybe e . (eitherToMaybe . decode <=< decodeHex) . cs
      where
        e = error "Could not read transaction from hex string"

instance NFData Tx where
    rnf (Tx v i o w l) = rnf v `seq` rnf i `seq` rnf o `seq` rnf w `seq` rnf l

instance Serialize Tx where
    get = parseWitnessTx <|> parseLegacyTx
    put tx
        | null (txWitness tx) = putLegacyTx tx
        | otherwise = putWitnessTx tx

putLegacyTx :: Tx -> Put
putLegacyTx (Tx v is os _ l) = do
    putWord32le v
    put $ VarInt $ fromIntegral $ length is
    forM_ is put
    put $ VarInt $ fromIntegral $ length os
    forM_ os put
    putWord32le l

putWitnessTx :: Tx -> Put
putWitnessTx (Tx v is os w l) = do
    putWord32le v
    putWord8 0x00
    putWord8 0x01
    put $ VarInt $ fromIntegral $ length is
    forM_ is put
    put $ VarInt $ fromIntegral $ length os
    forM_ os put
    putWitnessData w
    putWord32le l

parseLegacyTx :: Get Tx
parseLegacyTx = do
    v <- getWord32le
    is <- replicateList =<< get
    os <- replicateList =<< get
    l <- getWord32le
    return
        Tx
        {txVersion = v, txIn = is, txOut = os, txWitness = [], txLockTime = l}
  where
    replicateList (VarInt c) = replicateM (fromIntegral c) get

parseWitnessTx :: Get Tx
parseWitnessTx = do
    v <- getWord32le
    m <- getWord8
    f <- getWord8
    guard $ m == 0x00
    guard $ f == 0x01
    is <- replicateList =<< get
    os <- replicateList =<< get
    w <- parseWitnessData $ length is
    l <- getWord32le
    return
        Tx {txVersion = v, txIn = is, txOut = os, txWitness = w, txLockTime = l}
  where
    replicateList (VarInt c) = replicateM (fromIntegral c) get

parseWitnessData :: Int -> Get WitnessData
parseWitnessData n = replicateM n parseWitnessStack
  where
    parseWitnessStack = do
        VarInt i <- get
        replicateM (fromIntegral i) parseWitnessStackItem
    parseWitnessStackItem = do
        VarInt i <- get
        getByteString $ fromIntegral i


putWitnessData :: WitnessData -> Put
putWitnessData = mapM_ putWitnessStack
  where
    putWitnessStack ws = do
        put $ VarInt $ fromIntegral $ length ws
        mapM_ putWitnessStackItem ws
    putWitnessStackItem bs = do
        put $ VarInt $ fromIntegral $ BS.length bs
        putByteString bs

instance FromJSON Tx where
    parseJSON = withText "Tx" $
        maybe mzero return . (eitherToMaybe . decode <=< decodeHex) . cs

instance ToJSON Tx where
    toJSON = String . cs . encodeHex . encode

-- | Data type representing a transaction input.
data TxIn =
    TxIn {
           -- | Reference the previous transaction output (hash + position)
           prevOutput   :: !OutPoint
           -- | Script providing the requirements of the previous transaction
           -- output to spend those coins.
         , scriptInput  :: !ByteString
           -- | BIP-68:
           -- Relative lock-time using consensus-enforced sequence numbers
         , txInSequence :: !Word32
         } deriving (Eq, Show, Ord)

instance NFData TxIn where
    rnf (TxIn p i s) = rnf p `seq` rnf i `seq` rnf s

instance Serialize TxIn where
    get =
        TxIn <$> get <*> (readBS =<< get) <*> getWord32le
      where
        readBS (VarInt len) = getByteString $ fromIntegral len

    put (TxIn o s q) = do
        put o
        put $ VarInt $ fromIntegral $ BS.length s
        putByteString s
        putWord32le q

-- | Data type representing a transaction output.
data TxOut =
    TxOut {
            -- | Transaction output value.
            outValue     :: !Word64
            -- | Script specifying the conditions to spend this output.
          , scriptOutput :: !ByteString
          } deriving (Eq, Show, Ord)

instance NFData TxOut where
    rnf (TxOut v o) = rnf v `seq` rnf o

instance Serialize TxOut where
    get = do
        val <- getWord64le
        (VarInt len) <- get
        TxOut val <$> getByteString (fromIntegral len)

    put (TxOut o s) = do
        putWord64le o
        put $ VarInt $ fromIntegral $ BS.length s
        putByteString s

-- | The OutPoint is used inside a transaction input to reference the previous
-- transaction output that it is spending.
data OutPoint = OutPoint
    { -- | The hash of the referenced transaction.
      outPointHash  :: !TxHash
      -- | The position of the specific output in the transaction.
      -- The first output position is 0.
    , outPointIndex :: !Word32
    } deriving (Show, Read, Eq, Ord)

instance NFData OutPoint where
    rnf (OutPoint h i) = rnf h `seq` rnf i

instance FromJSON OutPoint where
    parseJSON = withText "OutPoint" $
        maybe mzero return . (eitherToMaybe . decode <=< decodeHex) . cs

instance ToJSON OutPoint where
    toJSON = String . cs . encodeHex . encode

instance Serialize OutPoint where
    get = do
        (h,i) <- liftM2 (,) get getWord32le
        return $ OutPoint h i
    put (OutPoint h i) = put h >> putWord32le i

-- | Outpoint used in coinbase transactions
nullOutPoint :: OutPoint
nullOutPoint =
    OutPoint
    { outPointHash =
          "0000000000000000000000000000000000000000000000000000000000000000"
    , outPointIndex = maxBound
    }

genesisTx :: Tx
genesisTx =
    Tx version [txin] [txout] [] locktime
  where
    version = 1
    txin = TxIn outpoint inputBS maxBound
    txout = TxOut 5000000000 (encodeOutputBS output)
    locktime = 0
    outpoint = OutPoint z maxBound
    Just inputBS = decodeHex $ fromString $
        "04ffff001d0104455468652054696d65732030332f4a616e2f323030392043686" ++
        "16e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f" ++
        "757420666f722062616e6b73"
    output = PayPK $ fromString $
        "04678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb" ++
        "649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5f"
    z = "0000000000000000000000000000000000000000000000000000000000000000"