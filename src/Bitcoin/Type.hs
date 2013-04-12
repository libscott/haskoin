module Bitcoin.Type 
( Type(..) 
, getBool
, putBool
, getWord8
, putWord8
, getWord16
, putWord16
, getWord32
, putWord32
, getWord64
, putWord64
, getByteString
, putByteString
, getPortNumber
, putPortNumber
, getNetworkMagic
, putNetworkMagic
, getMsgChkSum
, putMsgChkSum
, getIPv6
, putIPv6
, getHash
, putHash
) where

import Data.Word
import Data.Binary.Get
import Data.Binary.Put
import Control.Applicative

class Type a where
    get :: Get a
    put :: a -> Put

getBool :: Get Bool
getBool = go <$> getWord8
    where go 0 = False
          go 1 = True
          go x = error $ "getBool: Invalid Bool " ++ (show x)

putBool :: Bool -> Put
putBool True = putWord8 1
putBool False = putWord8 0

getWord16 = getWord16le
putWord16 = putWord16le

getWord32 = getWord32le
putWord32 = putWord32le

getWord64 = getWord64le
putWord64 = putWord64le

getPortNumber = getWord16be
putPortNumber = putWord16be

getNetworkMagic = getWord32be
putNetworkMagic = putWord32be

getMsgChkSum = getWord32be
putMsgChkSum = putWord32be

getIPv6 = (,) <$> getWord64be <*> getWord64be
putIPv6 (w1, w2) = putWord64be w1 >> putWord64be w2

getHash = (,,,) <$> getWord64be <*> getWord64be <*> getWord64be <*> getWord64be

putHash (w1, w2, w3, w4) = 
    putWord64be w1 >> putWord64be w2 >> putWord64be w3 >> putWord64be w4

