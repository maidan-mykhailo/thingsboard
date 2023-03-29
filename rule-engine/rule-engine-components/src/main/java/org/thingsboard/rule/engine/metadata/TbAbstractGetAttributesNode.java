/**
 * Copyright © 2016-2023 The Thingsboard Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.thingsboard.rule.engine.metadata;

import com.fasterxml.jackson.databind.node.ObjectNode;
import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.ListenableFuture;
import com.google.common.util.concurrent.MoreExecutors;
import org.apache.commons.collections.CollectionUtils;
import org.thingsboard.common.util.JacksonUtil;
import org.thingsboard.rule.engine.api.TbContext;
import org.thingsboard.rule.engine.api.TbNodeConfiguration;
import org.thingsboard.rule.engine.api.TbNodeException;
import org.thingsboard.rule.engine.api.util.TbNodeUtils;
import org.thingsboard.server.common.data.id.EntityId;
import org.thingsboard.server.common.data.kv.AttributeKvEntry;
import org.thingsboard.server.common.data.kv.BasicTsKvEntry;
import org.thingsboard.server.common.data.kv.JsonDataEntry;
import org.thingsboard.server.common.data.kv.KvEntry;
import org.thingsboard.server.common.data.kv.TsKvEntry;
import org.thingsboard.server.common.msg.TbMsg;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.NoSuchElementException;
import java.util.Objects;
import java.util.concurrent.ConcurrentHashMap;
import java.util.stream.Collectors;

import static org.thingsboard.common.util.DonAsynchron.withCallback;
import static org.thingsboard.server.common.data.DataConstants.CLIENT_SCOPE;
import static org.thingsboard.server.common.data.DataConstants.LATEST_TS;
import static org.thingsboard.server.common.data.DataConstants.SERVER_SCOPE;
import static org.thingsboard.server.common.data.DataConstants.SHARED_SCOPE;

public abstract class TbAbstractGetAttributesNode<C extends TbGetAttributesNodeConfiguration, T extends EntityId> extends TbAbstractNodeWithFetchTo<C> {
    private static final String VALUE = "value";
    private static final String TS = "ts";
    private boolean isTellFailureIfAbsent;
    private boolean getLatestValueWithTs;

    @Override
    public void init(TbContext ctx, TbNodeConfiguration configuration) throws TbNodeException {
        super.init(ctx, configuration);
        getLatestValueWithTs = config.isGetLatestValueWithTs();
        isTellFailureIfAbsent = config.isTellFailureIfAbsent();
    }

    @Override
    public void onMsg(TbContext ctx, TbMsg msg) throws TbNodeException {
        try {
            withCallback(
                    findEntityIdAsync(ctx, msg),
                    entityId -> safePutAttributes(ctx, msg, entityId),
                    t -> ctx.tellFailure(msg, t), ctx.getDbCallbackExecutor());
        } catch (Throwable th) {
            ctx.tellFailure(msg, th);
        }
    }

    protected abstract ListenableFuture<T> findEntityIdAsync(TbContext ctx, TbMsg msg);

    private void safePutAttributes(TbContext ctx, TbMsg msg, T entityId) {
        if (entityId == null || entityId.isNullUid()) {
            ctx.tellFailure(msg, new NoSuchElementException("Did not find entity! Msg ID: " + msg.getId()));
            return;
        }
        ObjectNode msgDataNode;
        if (FetchTo.DATA.equals(fetchTo)) {
            msgDataNode = getMsgDataAsObjectNode(msg);
        } else {
            msgDataNode = null;
        }
        var failuresMap = new ConcurrentHashMap<String, List<String>>();
        ListenableFuture<List<Map<String, ? extends List<? extends KvEntry>>>> allFutures = Futures.allAsList(
                getLatestTelemetry(ctx, entityId, TbNodeUtils.processPatterns(config.getLatestTsKeyNames(), msg), failuresMap),
                getAttrAsync(ctx, entityId, CLIENT_SCOPE, TbNodeUtils.processPatterns(config.getClientAttributeNames(), msg), failuresMap),
                getAttrAsync(ctx, entityId, SHARED_SCOPE, TbNodeUtils.processPatterns(config.getSharedAttributeNames(), msg), failuresMap),
                getAttrAsync(ctx, entityId, SERVER_SCOPE, TbNodeUtils.processPatterns(config.getServerAttributeNames(), msg), failuresMap)
        );
        withCallback(allFutures, futuresList -> {
            var msgMetaData = msg.getMetaData().copy();
            futuresList.stream().filter(Objects::nonNull).forEach(kvEntriesMap -> {
                kvEntriesMap.forEach((keyScope, kvEntryList) -> {
                    var prefix = getPrefix(keyScope);
                    kvEntryList.forEach(kvEntry -> {
                        var key = prefix + kvEntry.getKey();
                        if (FetchTo.DATA.equals(fetchTo)) {
                            JacksonUtil.addKvEntry(msgDataNode, kvEntry, key);
                        } else if (FetchTo.METADATA.equals(fetchTo)) {
                            msgMetaData.putValue(key, kvEntry.getValueAsString());
                        }
                    });
                });
            });

            TbMsg outMsg = null;
            if (FetchTo.DATA.equals(fetchTo)) {
                outMsg = TbMsg.transformMsgData(msg, JacksonUtil.toString(msgDataNode));
            } else if (FetchTo.METADATA.equals(fetchTo)) {
                outMsg = TbMsg.transformMsg(msg, msgMetaData);
            }

            if (failuresMap.isEmpty()) {
                ctx.tellSuccess(outMsg);
            } else {
                ctx.tellFailure(outMsg, reportFailures(failuresMap));
            }
        }, t -> ctx.tellFailure(msg, t), ctx.getDbCallbackExecutor());
    }

    private ListenableFuture<Map<String, List<AttributeKvEntry>>> getAttrAsync(TbContext ctx, EntityId entityId, String scope, List<String> keys, ConcurrentHashMap<String, List<String>> failuresMap) {
        if (CollectionUtils.isEmpty(keys)) {
            return Futures.immediateFuture(null);
        }
        var attributeKvEntryListFuture = ctx.getAttributesService().find(ctx.getTenantId(), entityId, scope, keys);
        return Futures.transform(attributeKvEntryListFuture, attributeKvEntryList -> {
            if (isTellFailureIfAbsent && attributeKvEntryList.size() != keys.size()) {
                getNotExistingKeys(attributeKvEntryList, keys).forEach(key -> computeFailuresMap(scope, failuresMap, key));
            }
            var mapAttributeKvEntry = new HashMap<String, List<AttributeKvEntry>>();
            mapAttributeKvEntry.put(scope, attributeKvEntryList);
            return mapAttributeKvEntry;
        }, MoreExecutors.directExecutor());
    }

    private ListenableFuture<Map<String, List<TsKvEntry>>> getLatestTelemetry(TbContext ctx, EntityId entityId, List<String> keys, ConcurrentHashMap<String, List<String>> failuresMap) {
        if (CollectionUtils.isEmpty(keys)) {
            return Futures.immediateFuture(null);
        }
        ListenableFuture<List<TsKvEntry>> latestTelemetryFutures = ctx.getTimeseriesService().findLatest(ctx.getTenantId(), entityId, keys);
        return Futures.transform(latestTelemetryFutures, tsKvEntries -> {
            var listTsKvEntry = new ArrayList<TsKvEntry>();
            tsKvEntries.forEach(tsKvEntry -> {
                if (tsKvEntry.getValue() == null) {
                    if (isTellFailureIfAbsent) {
                        computeFailuresMap(LATEST_TS, failuresMap, tsKvEntry.getKey());
                    }
                } else if (getLatestValueWithTs) {
                    listTsKvEntry.add(getValueWithTs(tsKvEntry));
                } else {
                    listTsKvEntry.add(new BasicTsKvEntry(tsKvEntry.getTs(), tsKvEntry));
                }
            });
            var mapTsKvEntry = new HashMap<String, List<TsKvEntry>>();
            mapTsKvEntry.put(LATEST_TS, listTsKvEntry);
            return mapTsKvEntry;
        }, MoreExecutors.directExecutor());
    }

    private TsKvEntry getValueWithTs(TsKvEntry tsKvEntry) {
        var mapper = FetchTo.DATA.equals(fetchTo) ? JacksonUtil.OBJECT_MAPPER : JacksonUtil.ALLOW_UNQUOTED_FIELD_NAMES_MAPPER;
        var value = JacksonUtil.newObjectNode(mapper);
        value.put(TS, tsKvEntry.getTs());
        JacksonUtil.addKvEntry(value, tsKvEntry, VALUE, mapper);
        return new BasicTsKvEntry(tsKvEntry.getTs(), new JsonDataEntry(tsKvEntry.getKey(), value.toString()));
    }

    private String getPrefix(String scope) {
        var prefix = "";
        switch (scope) {
            case CLIENT_SCOPE:
                prefix = "cs_";
                break;
            case SHARED_SCOPE:
                prefix = "shared_";
                break;
            case SERVER_SCOPE:
                prefix = "ss_";
                break;
        }
        return prefix;
    }

    private List<String> getNotExistingKeys(List<AttributeKvEntry> existingAttributesKvEntry, List<String> allKeys) {
        List<String> existingKeys = existingAttributesKvEntry.stream().map(KvEntry::getKey).collect(Collectors.toList());
        return allKeys.stream().filter(key -> !existingKeys.contains(key)).collect(Collectors.toList());
    }

    private void computeFailuresMap(String scope, ConcurrentHashMap<String, List<String>> failuresMap, String key) {
        List<String> failures = failuresMap.computeIfAbsent(scope, k -> new ArrayList<>());
        failures.add(key);
    }

    private RuntimeException reportFailures(ConcurrentHashMap<String, List<String>> failuresMap) {
        var errorMessage = new StringBuilder("The following attribute/telemetry keys is not present in the DB: ").append("\n");
        if (failuresMap.containsKey(CLIENT_SCOPE)) {
            errorMessage.append("\t").append("[" + CLIENT_SCOPE + "]:").append(failuresMap.get(CLIENT_SCOPE).toString()).append("\n");
        }
        if (failuresMap.containsKey(SERVER_SCOPE)) {
            errorMessage.append("\t").append("[" + SERVER_SCOPE + "]:").append(failuresMap.get(SERVER_SCOPE).toString()).append("\n");
        }
        if (failuresMap.containsKey(SHARED_SCOPE)) {
            errorMessage.append("\t").append("[" + SHARED_SCOPE + "]:").append(failuresMap.get(SHARED_SCOPE).toString()).append("\n");
        }
        if (failuresMap.containsKey(LATEST_TS)) {
            errorMessage.append("\t").append("[" + LATEST_TS + "]:").append(failuresMap.get(LATEST_TS).toString()).append("\n");
        }
        failuresMap.clear();
        return new RuntimeException(errorMessage.toString());
    }
}
