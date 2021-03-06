// Copyright (c) 2016-2017, Nefeli Networks, Inc.
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice, this
// list of conditions and the following disclaimer.
//
// * Redistributions in binary form must reproduce the above copyright notice,
// this list of conditions and the following disclaimer in the documentation
// and/or other materials provided with the distribution.
//
// * Neither the names of the copyright holders nor the names of their
// contributors may be used to endorse or promote products derived from this
// software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#include "url_filter.h"

#include <algorithm>
#include <tuple>
#include <iostream>
#include <string>

#include <hs.h>

#include "../utils/checksum.h"
#include "../utils/ether.h"
#include "../utils/format.h"
#include "../utils/http_parser.h"
#include "../utils/ip.h"

using bess::utils::Ethernet;
using bess::utils::Ipv4;
using bess::utils::Tcp;
using bess::utils::be16_t;

const uint64_t TIME_OUT_NS = 10ull * 1000 * 1000 * 1000;  // 10 seconds

const Commands UrlFilter::cmds = {};

static int fullScanHandler(unsigned int id, unsigned long long from,
                        unsigned long long to, unsigned int flags, void *ctx) {

    std::cout << "Pattern ID matched: " << id << std::endl;
    return 0;
}

CommandResponse UrlFilter::Init(const bess::pb::EmptyArg &) //
{
    /* hyperscan initalization */
    const std::vector<const char *> patterns{"^The", "abc{2,5}"};
    const std::vector<unsigned int> ids{0, 1};

    hs_compile_error_t *compile_err;

    if (hs_compile_multi(patterns.data(), NULL, ids.data(), patterns.size(), HS_MODE_BLOCK, NULL, &database,
                   &compile_err) != HS_SUCCESS) {
        hs_free_compile_error(compile_err);
        return CommandFailure(EINVAL, "error compiling regex patterns");
    }

    /* allocate scratch space to be used across many scans */
    if (hs_alloc_scratch(database, &scratch) != HS_SUCCESS) {
        hs_free_database(database);
        return CommandFailure(ENOMEM, "error allocating scratch space");
    }

    return CommandSuccess();
}

void UrlFilter::ProcessBatch(Context *ctx, bess::PacketBatch *batch) {
  gate_idx_t igate = ctx->current_igate;

  // ! What does this do?
  // Pass reverse traffic
  if (igate == 1) {
    RunChooseModule(ctx, 1, batch);
    return;
  }

  int cnt = batch->cnt();

  for (int i = 0; i < cnt; i++) {
    bess::Packet *pkt = batch->pkts()[i];

    Ethernet *eth = pkt->head_data<Ethernet *>();
    Ipv4 *ip = reinterpret_cast<Ipv4 *>(eth + 1);

    // ! if the protocol is not TCP then don't inspect the packet
    if (ip->protocol != Ipv4::Proto::kTcp) {
      EmitPacket(ctx, pkt, 0);
      continue;
    }

    // ! What will this variable be used for?
    int ip_bytes = ip->header_length << 2;
    Tcp *tcp =
        reinterpret_cast<Tcp *>(reinterpret_cast<uint8_t *>(ip) + ip_bytes);

    Flow flow;
    flow.src_ip = ip->src;
    flow.dst_ip = ip->dst;
    flow.src_port = tcp->src_port;
    flow.dst_port = tcp->dst_port;

    // ! Some kind of timestamp?
    uint64_t now = ctx->current_ns;

    // ! <Key, Values, Hash>
    // ! Iterator is created here 
    // Find existing flow, if we have one.
    std::unordered_map<Flow, FlowRecord, FlowHash>::iterator it =
        flow_cache_.find(flow);

    /**
     * * Throw out packets from flows that have expired or been analyzed.
     * * When is a flow considered to be analyzed?
     **/

    if (it != flow_cache_.end()) {
      if (now >= it->second.ExpiryTime()) {
        // Discard old flow and start over.
        flow_cache_.erase(it);
        it = flow_cache_.end();
      }
    }

    // ! Create a new flow entry
    if (it == flow_cache_.end()) {
      // Don't have a flow, or threw an aged one out.  If there's no
      // SYN in this packet the reconstruct code will fail.  This is
      // a common case (for any flow that got analyzed and allowed);
      // skip a pointless emplace/erase pair for such packets.
      if (tcp->flags & Tcp::Flag::kSyn) {
        std::tie(it, std::ignore) = flow_cache_.emplace(
            std::piecewise_construct, std::make_tuple(flow), std::make_tuple());
      } else {
        EmitPacket(ctx, pkt, 0);
        continue;
      }
    }

    FlowRecord &record = it->second;
    TcpFlowReconstruct &buffer = record.GetBuffer();

    // If the reconstruct code indicates failure, treat this
    // as a flow to pass.  Note: we only get failure if there is
    // something seriously wrong; we get success if there are holes
    // in the data (in which case the contiguous_len() below is short).
    bool success = buffer.InsertPacket(pkt);
    if (!success) {
      VLOG(1) << "Reconstruction failure";
      flow_cache_.erase(it);
      EmitPacket(ctx, pkt, 0);
      continue;
    }

    // Have something on this flow; keep it alive for a while longer.
    record.SetExpiryTime(now + TIME_OUT_NS);

    EmitPacket(ctx, pkt, 0);

    if (tcp->flags & Tcp::Flag::kFin) {
      const char *buffer_data = buffer.buf();
      unsigned int buffer_length = sizeof(buffer_data);

      /* perform full scan on reconstructed buffer data */
      if (hs_scan(database, buffer_data, buffer_length, 0, scratch, fullScanHandler, nullptr) != HS_SUCCESS) {
        hs_free_scratch(scratch);
        hs_free_database(database);
        std::cout << "scan failed" << std::endl;
      }
    }

  }
}

ADD_MODULE(UrlFilter, "url-filter", "Filter HTTP connection")
