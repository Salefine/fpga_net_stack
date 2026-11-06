# :telephone_receiver: *RDMA*协议格式

RoCEv2（RDMA over Converged Ethernet v2）是在 UDP/IP 网络之上承载 InfiniBand RDMA 传输层协议的技术。

如果从 FPGA 硬件解析和封包实现的角度来看，可以把 RoCEv2 数据包分成以下几层：

1. Ethernet Header：以太网帧头。
2. IP Header：IPv4 或 IPv6 头。
3. UDP Header：UDP 头，目的端口通常为 `4791`。
4. BTH：Base Transport Header，RoCEv2 的基本传输层头。
5. Extended Headers：扩展头，根据操作类型决定是否存在。
6. Payload：数据负载。
7. ICRC：Invariant CRC，RoCEv2 使用的传输完整性校验字段。

## :penguin: 1. RoCEv2 整体报文格式

下面用 ASCII 表格表示一个典型的 RoCEv2 IPv4 数据包：

```cmd
+--------------------------------------------------+
|                Ethernet Header                   |
|                  14 Bytes                        |
+--------------------------------------------------+
|                  IPv4 Header                     |
|                  20 Bytes                        |
+--------------------------------------------------+
|                   UDP Header                     |
|                   8 Bytes                        |
+--------------------------------------------------+
|             BTH (Base Transport Header)          |
|                  12 Bytes                        |
+--------------------------------------------------+
|              Extended Headers                    |
|             (Optional, Variable)                 |
+--------------------------------------------------+
|                                                  |
|                   Payload                        |
|                  Variable                        |
|                                                  |
+--------------------------------------------------+
|                    ICRC                          |
|                   4 Bytes                        |
+--------------------------------------------------+
```

说明：以上是无 VLAN、无 IP Options 的 IPv4 基本格式。不同 RDMA 操作的扩展头不同，不能认为每个报文都有相同的头部长度。

## :penguin: 2. BTH（基础传输头）格式

BTH 是 RoCEv2 最重要的头部，固定长度为 12 Bytes。无论是 RDMA WRITE、RDMA READ 还是 SEND 操作，都需要 BTH。

下面按照 32-bit（4 字节）对齐展示：

```cmd
        BTH (12 Bytes)
+-----------------------------------------------+
| Byte 0: OpCode             (8 bits)            |
+-----------------------------------------------+
| Byte 1: SE | M | PadCnt | TVer (8 bits)       |
+-----------------------------------------------+
| Byte 2-3: P_Key            (16 bits)           |
+-----------------------------------------------+
| Byte 4-6: Destination QP   (24 bits)           |
+-----------------------------------------------+
| Byte 7: AckReq | Reserved  (8 bits)            |
+-----------------------------------------------+
| Byte 8-10: Packet Sequence Number (24 bits)   |
+-----------------------------------------------+
| Byte 11: Reserved          (8 bits)            |
+-----------------------------------------------+
```

各字段的含义：

| 字段           | 长度   | 含义                                  |
| -------------- | ------ | ------------------------------------- |
| OpCode         | 8 bit  | 操作码，标识 SEND、WRITE、READ 等操作 |
| SE             | 1 bit  | Solicited Event                       |
| M              | 1 bit  | Migration Request                     |
| PadCnt         | 2 bit  | Payload 填充字节数                    |
| TVer           | 4 bit  | Transport Header Version              |
| P_Key          | 16 bit | Partition Key                         |
| Destination QP | 24 bit | 接收端 Queue Pair 编号                |
| AckReq         | 1 bit  | 请求接收端返回 ACK                    |
| Reserved       | 7 bit  | 保留位                                |
| PSN            | 24 bit | Packet Sequence Number，包序列号      |
| Reserved       | 8 bit  | 保留位                                |

几个特别重要的字段：

- `OpCode`：决定后续扩展头如何解析。
- `Destination QP`：决定数据应该送到哪个接收队列。
- `PSN`：用于可靠传输中的包序列管理。
- `AckReq`：用于控制是否请求 ACK。

## :penguin: 3. 不同 RDMA 操作的扩展头

BTH 后面不一定直接跟 Payload。具体格式由 OpCode 决定。

其中常见扩展头如下：

| RDMA 操作                      | OpCode（二进制） | OpCode（十六进制） | 扩展头格式                     |
| ------------------------------ | ---------------- | ------------------ | ------------------------------ |
| SEND FIRST                     | `00000000`       | `0x00`             | BTH + Payload                  |
| SEND MIDDLE                    | `00000001`       | `0x01`             | BTH + Payload                  |
| SEND LAST                      | `00000010`       | `0x02`             | BTH + Payload                  |
| SEND LAST WITH IMMEDIATE       | `00000011`       | `0x03`             | BTH + ImmData + Payload        |
| SEND ONLY                      | `00000100`       | `0x04`             | BTH + Payload                  |
| SEND ONLY WITH IMMEDIATE       | `00000101`       | `0x05`             | BTH + ImmData + Payload        |
| RDMA WRITE FIRST               | `00000110`       | `0x06`             | BTH + RETH + Payload           |
| RDMA WRITE MIDDLE              | `00000111`       | `0x07`             | BTH + Payload                  |
| RDMA WRITE LAST                | `00001000`       | `0x08`             | BTH + Payload                  |
| RDMA WRITE LAST WITH IMMEDIATE | `00001001`       | `0x09`             | BTH + ImmData + Payload        |
| RDMA WRITE ONLY                | `00001010`       | `0x0A`             | BTH + RETH + Payload           |
| RDMA WRITE ONLY WITH IMMEDIATE | `00001011`       | `0x0B`             | BTH + RETH + ImmData + Payload |
| RDMA READ REQUEST              | `00001100`       | `0x0C`             | BTH + RETH                     |
| RDMA READ RESPONSE FIRST       | `00001101`       | `0x0D`             | BTH + AETH + Payload           |
| RDMA READ RESPONSE MIDDLE      | `00001110`       | `0x0E`             | BTH + Payload                  |
| RDMA READ RESPONSE LAST        | `00001111`       | `0x0F`             | BTH + AETH + Payload           |
| RDMA READ RESPONSE ONLY        | `00010000`       | `0x10`             | BTH + AETH + Payload           |
| ACK                            | `00010001`       | `0x11`             | BTH + AETH                     |

RETH（16 Bytes）：

```cmd
+-----------------------------------------------+
| Virtual Address (64 bits)                     |
+-----------------------------------------------+
| R_Key (32 bits)                               |
+-----------------------------------------------+
| DMA Length (32 bits)                          |
+-----------------------------------------------+
```

AETH（4 Bytes）：

```cmd
+-----------------------------------------------+
| Syndrome (8 bits)                             |
+-----------------------------------------------+
| Message Sequence Number (24 bits)             |
+-----------------------------------------------+
```

RETH 用于告诉接收端远程内存的地址、访问密钥和数据长度；AETH 用于 ACK、读响应等可靠传输控制。

## :penguin: 4. UD（Unreliable Datagram）报文示例

如果使用 RoCEv2 UD 模式，BTH 后面还会有一个 DETH（Datagram Extended Transport Header），长度为 8 Bytes。

```cmd
+-----------------------------------------------+
| Ethernet Header                 14 Bytes      |
+-----------------------------------------------+
| IPv4 Header                     20 Bytes      |
+-----------------------------------------------+
| UDP Header                       8 Bytes      |
|   Destination Port = 4791                      |
+-----------------------------------------------+
| BTH                             12 Bytes      |
+-----------------------------------------------+
| DETH                             8 Bytes      |
|   Q_Key                                         |
|   Source QP                                     |
+-----------------------------------------------+
| Payload                         N Bytes       |
+-----------------------------------------------+
| ICRC                             4 Bytes      |
+-----------------------------------------------+
| Ethernet FCS                     4 Bytes      |
+-----------------------------------------------+
```

