{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TupleSections              #-}
--------------------------------------------------------------------------------
-- |
-- Module      :  Network.MQTT.Message
-- Copyright   :  (c) Lars Petersen 2016
-- License     :  MIT
--
-- Maintainer  :  info@lars-petersen.net
-- Stability   :  experimental
--------------------------------------------------------------------------------
module Network.MQTT.Message
  ( ClientIdentifier
  , SessionPresent
  , CleanSession
  , Retain
  , KeepAliveInterval
  , Username
  , Password
  , PacketIdentifier (..)
  , QualityOfService (..)
  , ConnectionRefusal (..)
  , Message (..)
  , ClientMessage (..)
  , buildClientMessage
  , parseClientMessage
  , ServerMessage (..)
  , buildServerMessage
  , parseServerMessage
  , lengthParser
  , lengthBuilder
  , utf8Parser
  , utf8Builder
  ) where

import           Control.Monad
import qualified Data.Attoparsec.ByteString as A
import           Data.Bits
import qualified Data.ByteString            as BS
import qualified Data.ByteString.Builder    as BS
import qualified Data.ByteString.Lazy       as BSL
import           Data.Monoid
import qualified Data.Serialize.Get         as SG
import qualified Data.Text                  as T
import qualified Data.Text.Encoding         as T
import           Data.Word
import qualified Network.MQTT.Topic         as TF

type SessionPresent   = Bool
type CleanSession     = Bool
type Retain           = Bool
type Duplicate        = Bool
type KeepAliveInterval = Word16
type Username         = T.Text
type Password         = BS.ByteString
type ClientIdentifier = T.Text

newtype PacketIdentifier = PacketIdentifier Int
  deriving (Eq, Ord, Show)

data QualityOfService
  = Qos0
  | Qos1
  | Qos2
  deriving (Eq, Ord, Show)

data ConnectionRefusal
   = UnacceptableProtocolVersion
   | IdentifierRejected
   | ServerUnavailable
   | BadUsernameOrPassword
   | NotAuthorized
   deriving (Eq, Ord, Show, Enum, Bounded)

data Message
   = Message
   { msgTopic     :: !TF.Topic
   , msgBody      :: !BSL.ByteString
   , msgQos       :: !QualityOfService
   , msgRetain    :: !Retain
   , msgDuplicate :: !Duplicate
   } deriving (Eq, Ord, Show)

data ClientMessage
   = ClientConnect
     { connectClientIdentifier :: !ClientIdentifier
     , connectCleanSession     :: !CleanSession
     , connectKeepAlive        :: !KeepAliveInterval
     , connectWill             :: !(Maybe Message)
     , connectCredentials      :: !(Maybe (Username, Maybe Password))
     }
   | ClientSubscribe                    PacketIdentifier [(TF.Filter, QualityOfService)]
   | ClientUnsubscribe                  PacketIdentifier [TF.Filter]
   | ClientPingRequest
   | ClientDisconnect
   deriving (Eq, Show)

data ServerMessage
   = ConnectAck !(Either ConnectionRefusal SessionPresent)
   | PingResponse
   | Publish                                                      !Message
   | Publish'                    {-# UNPACK #-} !PacketIdentifier !Message
   | PublishAcknowledgement      {-# UNPACK #-} !PacketIdentifier
   | PublishReceived             {-# UNPACK #-} !PacketIdentifier
   | PublishRelease              {-# UNPACK #-} !PacketIdentifier
   | PublishComplete             {-# UNPACK #-} !PacketIdentifier
   | SubscribeAcknowledgement    {-# UNPACK #-} !PacketIdentifier [Maybe QualityOfService]
   | UnsubscribeAcknowledgement  {-# UNPACK #-} !PacketIdentifier
   deriving (Eq, Show)

parseClientMessage :: SG.Get ClientMessage
parseClientMessage =
  SG.lookAhead SG.getWord8 >>= \h-> case h .&. 0xf0 of
    0x10 -> pConnect
    0x80 -> undefined --pSubscribe
    0xa0 -> undefined --pUnsubscribe
    0xc0 -> pPingRequest
    0xe0 -> pDisconnect
    _    -> fail "parseClientMessage: Invalid message type."

parseServerMessage :: SG.Get ServerMessage
parseServerMessage =
  SG.lookAhead SG.getWord8 >>= \h-> case h .&. 0xf0 of
    0x20 -> pConnectAcknowledgement
    0x30 -> pPublish
    0x40 -> pPublishAcknowledgement
    0x50 -> pPublishReceived
    0x60 -> pPublishRelease
    0x70 -> pPublishComplete
    0x90 -> undefined -- pSubscribeAcknowledgement
    0xb0 -> pUnsubscribeAcknowledgement
    0xd0 -> pPingResponse
    _    -> fail "pServerMessage: Packet type not implemented."



pConnect :: SG.Get ClientMessage
pConnect = do
  h <- SG.getWord8
  when (h .&. 0x0f /= 0) $
    fail "pConnect: The header flags are reserved and MUST be set to 0."
  void lengthParser -- the remaining length is redundant in this packet type
  y <- SG.getWord64be -- get the next 8 bytes all at once and not byte per byte
  when (y .&. 0xffffffffffffff00 /= 0x00044d5154540400) $
    fail "pConnect: Unexpected protocol initialization."
  let cleanSession = y .&. 0x02 /= 0
  keepAlive <- SG.getWord16be
  cid       <- utf8Parser
  will      <- if y .&. 0x04 == 0
    then pure Nothing
    else Just <$> do
      topic      <- fst <$> topicParser
      bodyLen    <- fromIntegral <$> SG.getWord16be
      body       <- SG.getLazyByteString bodyLen
      qos        <- case y .&. 0x18 of
        0x00 -> pure Qos0
        0x08 -> pure Qos1
        0x10 -> pure Qos2
        _    -> fail "pConnect: Violation of [MQTT-3.1.2-14]."
      pure $ Message topic body qos ( y .&. 0x20 /= 0 ) False
  cred  <- if y .&. 0x80 == 0
    then pure Nothing
    else Just <$> ( (,)
      <$> utf8Parser
      <*> if y .&. 0x40 == 0
            then pure Nothing
            else Just <$> (SG.getWord16be >>= SG.getByteString . fromIntegral) )
  pure ( ClientConnect cid cleanSession keepAlive will cred )

pConnectAcknowledgement :: SG.Get ServerMessage
pConnectAcknowledgement = do
  x <- SG.getWord32be
  ConnectAck <$> case x .&. 0xff of
    0 -> pure $ Right (x .&. 0x0100 /= 0)
    1 -> pure $ Left UnacceptableProtocolVersion
    2 -> pure $ Left IdentifierRejected
    3 -> pure $ Left ServerUnavailable
    4 -> pure $ Left BadUsernameOrPassword
    5 -> pure $ Left NotAuthorized
    _ -> fail "pConnectAcknowledgement: Invalid (reserved) return code."

pPublish :: SG.Get ServerMessage
pPublish = do
  hflags <- SG.getWord8
  let dup = hflags .&. 0x08 /= 0 -- duplicate flag
  let ret = hflags .&. 0x01 /= 0 -- retain flag
  len <- lengthParser
  (topic, topicLen)  <- topicParser
  let qosBits = hflags .&. 0x06
  if  qosBits == 0x00
    then do
      body <- SG.getLazyByteString $ fromIntegral ( len - topicLen )
      pure (Publish $ Message topic body Qos0 dup ret)
    else do
      let qos = if qosBits == 0x02 then Qos1 else Qos2
      pid  <- PacketIdentifier . fromIntegral <$> SG.getWord16be
      body <- SG.getLazyByteString $ fromIntegral ( len - topicLen - 2 )
      pure (Publish' pid $ Message topic body qos dup ret)

pPublishAcknowledgement :: SG.Get ServerMessage
pPublishAcknowledgement = do
    w32 <- SG.getWord32be
    pure $ PublishAcknowledgement $ PacketIdentifier $ fromIntegral $ w32 .&. 0xffff

pPublishReceived :: SG.Get ServerMessage
pPublishReceived = do
    w32 <- SG.getWord32be
    pure $ PublishReceived $ PacketIdentifier $ fromIntegral $ w32 .&. 0xffff

pPublishRelease :: SG.Get ServerMessage
pPublishRelease = do
    w32 <- SG.getWord32be
    pure $ PublishRelease $ PacketIdentifier $ fromIntegral $ w32 .&. 0xffff

pPublishComplete :: SG.Get ServerMessage
pPublishComplete = do
    w32 <- SG.getWord32be
    pure $ PublishComplete $ PacketIdentifier $ fromIntegral $ w32 .&. 0xffff

{-
pSubscribe :: SG.Get ClientMessage
pSubscribe = do
  _    <- SG.getWord8
  rlen <- lengthParser
  pid  <- PacketIdentifier . fromIntegral <$> SG.getWord16be
  Subscribe pid <$> getTopics (rlen - 2) []
  where
    getTopics 0 ts = pure (reverse ts)
    getTopics r ts = do
      len <- fromIntegral <$> SG.getWord16be
      t   <- SG.getByteString len
      qos <- getQoS
      getTopics ( r - 3 - len ) ( ( T.decodeUtf8 t, qos ) : ts )
    getQoS = SG.getWord8 >>= \w-> case w of
        0x00 -> pure QoS0
        0x01 -> pure QoS1
        0x02 -> pure QoS2
        _    -> fail $ "pSubscribe: Violation of [MQTT-3.8.3-4]."

pSubscribeAcknowledgement :: SG.Get ServerMessage
pSubscribeAcknowledgement = do
  _    <- SG.getWord8
  rlen <- lengthParser
  pid  <- PacketIdentifier . fromIntegral <$> SG.getWord16be
  SubscribeAcknowledgement pid <$> (map f . BS.unpack <$> SG.getBytes (rlen - 2))
  where
    f 0x00 = Just QoS0
    f 0x01 = Just QoS1
    f 0x02 = Just QoS2
    f    _ = Nothing

pUnsubscribe :: SG.Get ClientMessage
pUnsubscribe = do
  header <- SG.getWord8
  rlen   <- lengthParser
  pid    <- SG.getWord16be
  Unsubscribe (PacketIdentifier $ fromIntegral pid) <$> f (rlen - 2) []
  where
    f 0 ts = pure (reverse ts)
    f r ts = do
      len <- fromIntegral <$> SG.getWord16be
      t   <- SG.getByteString len
      f (r - 2 - len) (T.decodeUtf8 t:ts)
      -}

pUnsubscribeAcknowledgement :: SG.Get ServerMessage
pUnsubscribeAcknowledgement = do
  x <- fromIntegral <$> SG.getWord32be
  pure $ UnsubscribeAcknowledgement $ PacketIdentifier (x .&. 0xffff)

pPingRequest :: SG.Get ClientMessage
pPingRequest = do
  _ <- SG.getWord16be
  pure ClientPingRequest

pPingResponse :: SG.Get ServerMessage
pPingResponse = do
  _ <- SG.getWord16be
  pure PingResponse

pDisconnect :: SG.Get ClientMessage
pDisconnect = do
  _ <- SG.getWord16be
  pure ClientDisconnect

buildClientMessage :: ClientMessage -> BS.Builder
buildClientMessage (ClientConnect cid cleanSession keepAlive will credentials) =
  BS.word8 0x10
  <> lengthBuilder ( 10 + cidLen + willLen + credLen )
  <> BS.word64BE ( 0x00044d5154540400 .|. willFlag .|. credFlag .|. sessFlag )
  <> BS.word16BE keepAlive
  <> cidBuilder
  <> willBuilder
  <> credBuilder
  where
    sessFlag = if cleanSession then 0x02 else 0x00
    (cidBuilder, cidLen) = utf8Builder cid
    (willBuilder, willLen, willFlag) = case will of
      Nothing ->
        (mempty, 0, 0x00)
      Just (Message t b q r _)->
       let tlen  = TF.topicLength t
           blen  = fromIntegral (BSL.length b)
           qflag = case q of
             Qos0 -> 0x04
             Qos1 -> 0x0c
             Qos2 -> 0x14
           rflag = if r then 0x20 else 0x00
           x1 = BS.word16BE (fromIntegral tlen)
           x2 = TF.topicBuilder t
           x3 = BS.word16BE (fromIntegral blen)
           x4 = BS.lazyByteString b
       in  (x1 <> x2 <> x3 <> x4, 4 + tlen + blen, qflag .|. rflag)
    (credBuilder, credLen, credFlag) = case credentials of
      Nothing           ->
        (mempty, 0, 0x00)
      Just (ut, Nothing) ->
        let u    = T.encodeUtf8 ut
            ulen = BS.length u
            x1   = BS.word16BE (fromIntegral ulen)
            x2   = BS.byteString u
        in (x1 <> x2, 2 + ulen, 0x80)
      Just (ut, Just p)  ->
        let u    = T.encodeUtf8 ut
            ulen = BS.length u
            plen = BS.length p
            x1   = BS.word16BE (fromIntegral ulen)
            x2   = BS.byteString u
            x3   = BS.word16BE (fromIntegral plen)
            x4   = BS.byteString p
        in (x1 <> x2 <> x3 <> x4, 4 + ulen + plen, 0xc0)
{-
buildClientMessage (Subscribe (PacketIdentifier p) tf)  =
  BS.word8 0x82 <> lengthBuilder len <> BS.word16BE (fromIntegral p) <> mconcat ( map f tf )
  where
    f (t, q) = (bUtf8String t <>) $ BS.word8 $ case q of
      Qos0 -> 0x00
      Qos1 -> 0x01
      Qos2 -> 0x02
    len  = 2 + length tf * 3 + sum ( map (BS.length . T.encodeUtf8 . fst) tf )
buildClientMessage (Unsubscribe (PacketIdentifier p) tfs) =
  BS.word8 0xa2 <> lengthBuilder len
    <> BS.word16BE (fromIntegral p) <> mconcat ( map bUtf8String tfs )
  where
    bfs = map T.encodeUtf8 tfs
    len = 2 + sum ( map ( ( + 2 ) . BS.length ) bfs )
-}
buildClientMessage ClientPingRequest =
  BS.word16BE 0xc000
buildClientMessage ClientDisconnect =
  BS.word16BE 0xe000

buildServerMessage :: ServerMessage -> BS.Builder
buildServerMessage (ConnectAck crs) =
  BS.word32BE $ 0x20020000 .|. case crs of
    Left cr -> fromIntegral $ fromEnum cr + 1
    Right s -> if s then 0x0100 else 0

{-
buildServerMessage (Publish d r t qos b) =
  case qos of
    PublishQoS0 ->
      let len = 2 + BS.length t + BS.length b
          h   = fromIntegral $ (if r then 0x31000000 else 0x30000000)
                .|. len `unsafeShiftL` 16
                .|. BS.length t
      in if len < 128
        then BS.word32BE h
          <> BS.byteString t
          <> BS.byteString b
        else BS.word8 ( if r then 0x31 else 0x30 )
          <> lengthBuilder len
          <> BS.word16BE ( fromIntegral $ BS.length t )
          <> BS.byteString t
          <> BS.byteString b
    PublishQoS1 dup (PacketIdentifier pid) ->
      let len = 4 + BS.length t + BS.length b
      in BS.word8 ( 0x30
        .|. ( if dup then 0x08 else 0 )
        .|. ( if r then 0x01 else 0 )
        .|. 0x02 )
      <> lengthBuilder len
      <> BS.word16BE ( fromIntegral $ BS.length t )
      <> BS.byteString t
      <> BS.word16BE (fromIntegral pid)
      <> BS.byteString b
    PublishQoS2 (PacketIdentifier pid) ->
      let tLen = topicLength t;
          len = 4 + tLen + BS.length b
      in BS.word8 ( 0x30 .|. ( if r then 0x01 else 0x00 ) .|. 0x04 )
      <> lengthBuilder len
      <> BS.word16BE (fromIntegral tLen)
      <> topicBuilder t
      <> BS.word16BE (fromIntegral pid)
      <> BS.byteString b
-}
buildServerMessage (PublishAcknowledgement (PacketIdentifier p)) =
  BS.word32BE $ fromIntegral $ 0x40020000 .|. p
buildServerMessage (PublishReceived (PacketIdentifier p)) =
  BS.word32BE $ fromIntegral $ 0x50020000 .|. p
buildServerMessage (PublishRelease (PacketIdentifier p)) =
  BS.word32BE $ fromIntegral $ 0x62020000 .|. p
buildServerMessage (PublishComplete (PacketIdentifier p)) =
  BS.word32BE $ fromIntegral $ 0x70020000 .|. p
buildServerMessage (SubscribeAcknowledgement (PacketIdentifier p) rcs) =
  BS.word8 0x90 <> lengthBuilder (2 + length rcs)
    <> BS.word16BE (fromIntegral p) <> mconcat ( map ( BS.word8 . f ) rcs )
  where
    f Nothing     = 0x80
    f (Just Qos0) = 0x00
    f (Just Qos1) = 0x01
    f (Just Qos2) = 0x02

buildServerMessage (UnsubscribeAcknowledgement (PacketIdentifier p)) =
  BS.word16BE 0xb002 <> BS.word16BE (fromIntegral p)
buildServerMessage PingResponse =
  BS.word16BE 0xd000

--------------------------------------------------------------------------------
-- Utils
--------------------------------------------------------------------------------

topicParser :: SG.Get (TF.Topic, Int)
topicParser = do
  topicLen   <- fromIntegral <$> SG.getWord16be
  topicBytes <- SG.getByteString topicLen
  case A.parseOnly TF.topicParser topicBytes of
    Right t -> pure (t, topicLen + 2)
    Left  _ -> fail "topicParser: Invalid topic."
{-# INLINE topicParser #-}

utf8Parser :: SG.Get T.Text
utf8Parser = do
  str <- SG.getWord16be >>= SG.getByteString . fromIntegral
  when (BS.elem 0x00 str) (fail "utf8Parser: Violation of [MQTT-1.5.3-2].")
  case T.decodeUtf8' str of
    Right txt -> return txt
    _         -> fail "utf8Parser: Violation of [MQTT-1.5.3]."
{-# INLINE utf8Parser #-}

utf8Builder :: T.Text -> (BS.Builder, Int)
utf8Builder txt =
  if len > 0xffff
    then error "utf8Builder: Encoded size must be <= 0xffff."
    else (BS.word16BE (fromIntegral len) <> BS.byteString bs, len + 2)
  where
    bs  = T.encodeUtf8 txt
    len = BS.length bs
{-# INLINE utf8Builder #-}

lengthParser:: SG.Get Int
lengthParser = do
  b0 <- fromIntegral <$> SG.getWord8
  if b0 < 128
    then pure b0
     else do
       b1 <- fromIntegral <$> SG.getWord8
       if b1 < 128
        then pure $ b1 * 128 + (b0 .&. 127)
        else do
          b2 <- fromIntegral <$> SG.getWord8
          if b2 < 128
            then pure $ b2 * 128 * 128 + (b1 .&. 127) * 128 + (b0 .&. 127)
            else do
              b3 <- fromIntegral <$> SG.getWord8
              if b3 < 128
                then pure $ b3 * 128 * 128 * 128 + (b2 .&. 127) * 128 * 128 + (b1 .&. 127) * 128 + (b0 .&. 127)
                else fail "lengthParser: invalid input"
{-# INLINE lengthParser #-}

lengthBuilder :: Int -> BS.Builder
lengthBuilder i
  | i < 0x80                = BS.word8    ( fromIntegral i )
  | i < 0x80*0x80           = BS.word16LE $ fromIntegral $ 0x0080 -- continuation bit
                                         .|.              ( i .&. 0x7f      )
                                         .|. unsafeShiftL ( i .&. 0x3f80    )  1
  | i < 0x80*0x80*0x80      = BS.word16LE ( fromIntegral $ 0x8080
                                         .|.              ( i .&. 0x7f      )
                                         .|. unsafeShiftL ( i .&. 0x3f80    )  1
                                          )
                           <> BS.word8    ( fromIntegral
                                          $ unsafeShiftR ( i .&. 0x1fc000   ) 14
                                          )
  | i < 0x80*0x80*0x80*0x80 = BS.word32LE $ fromIntegral $ 0x00808080
                                         .|.              ( i .&. 0x7f      )
                                         .|. unsafeShiftL ( i .&. 0x3f80    )  1
                                         .|. unsafeShiftL ( i .&. 0x1fc000  )  2
                                         .|. unsafeShiftL ( i .&. 0x0ff00000)  3
  | otherwise               = error "sRemainingLength: invalid input"
{-# INLINE lengthBuilder #-}
