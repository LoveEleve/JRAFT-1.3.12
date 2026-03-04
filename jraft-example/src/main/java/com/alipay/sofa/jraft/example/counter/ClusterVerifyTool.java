/*
 * Licensed to the Apache Software Foundation (ASF) under one or more
 * contributor license agreements.  See the NOTICE file distributed with
 * this work for additional information regarding copyright ownership.
 * The ASF licenses this file to You under the Apache License, Version 2.0
 * (the "License"); you may not use this file except in compliance with
 * the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
/*
 * JRaft 集群验证工具：成员变更 + Leader 转移
 */
package com.alipay.sofa.jraft.example.counter;

import com.alipay.sofa.jraft.CliService;
import com.alipay.sofa.jraft.RaftServiceFactory;
import com.alipay.sofa.jraft.RouteTable;
import com.alipay.sofa.jraft.Status;
import com.alipay.sofa.jraft.conf.Configuration;
import com.alipay.sofa.jraft.entity.PeerId;
import com.alipay.sofa.jraft.example.counter.rpc.CounterGrpcHelper;
import com.alipay.sofa.jraft.option.CliOptions;

public class ClusterVerifyTool {

    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.out.println("Usage:");
            System.out.println("  getLeader  <conf>");
            System.out.println("  getPeers   <conf>");
            System.out.println("  addPeer    <conf> <newPeer>");
            System.out.println("  removePeer <conf> <peer>");
            System.out.println("  transferLeader <conf> <targetPeer>");
            System.out
                .println("Example: java ... ClusterVerifyTool getLeader 127.0.0.1:8081,127.0.0.1:8082,127.0.0.1:8083");
            System.exit(1);
        }

        String command = args[0];
        String confStr = args[1];
        String groupId = "counter";

        CounterGrpcHelper.initGRpc();

        Configuration conf = new Configuration();
        if (!conf.parse(confStr)) {
            throw new IllegalArgumentException("Fail to parse conf: " + confStr);
        }

        RouteTable.getInstance().updateConfiguration(groupId, conf);

        CliService cliService = RaftServiceFactory.createAndInitCliService(new CliOptions());

        switch (command) {
            case "getLeader": {
                PeerId leader = new PeerId();
                Status st = cliService.getLeader(groupId, conf, leader);
                System.out.println("[getLeader] Status: " + st);
                System.out.println("[getLeader] Leader: " + leader);
                break;
            }
            case "getPeers": {
                System.out.println("[getPeers] Peers: " + cliService.getPeers(groupId, conf));
                System.out.println("[getPeers] Alive Peers: " + cliService.getAlivePeers(groupId, conf));
                break;
            }
            case "addPeer": {
                if (args.length < 3) {
                    System.out.println("Missing newPeer argument");
                    System.exit(1);
                }
                PeerId newPeer = new PeerId();
                newPeer.parse(args[2]);
                System.out.println("[addPeer] Adding peer: " + newPeer);
                Status st = cliService.addPeer(groupId, conf, newPeer);
                System.out.println("[addPeer] Status: " + st);
                break;
            }
            case "removePeer": {
                if (args.length < 3) {
                    System.out.println("Missing peer argument");
                    System.exit(1);
                }
                PeerId peer = new PeerId();
                peer.parse(args[2]);
                System.out.println("[removePeer] Removing peer: " + peer);
                Status st = cliService.removePeer(groupId, conf, peer);
                System.out.println("[removePeer] Status: " + st);
                break;
            }
            case "transferLeader": {
                if (args.length < 3) {
                    System.out.println("Missing targetPeer argument");
                    System.exit(1);
                }
                PeerId target = new PeerId();
                target.parse(args[2]);
                System.out.println("[transferLeader] Transferring leader to: " + target);
                Status st = cliService.transferLeader(groupId, conf, target);
                System.out.println("[transferLeader] Status: " + st);
                break;
            }
            default:
                System.out.println("Unknown command: " + command);
                System.exit(1);
        }

        System.exit(0);
    }
}
