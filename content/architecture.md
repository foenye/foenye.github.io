+++
date = '2026-03-13T13:43:17+08:00'
draft = true
title = 'Architecture'
+++
# 平台微服务架构设计与商家入驻流程技术方案

本文档阐述基于 **Spring Boot + Spring for GraphQL Federation + Event Driven** 的云原生友好微服务架构设计，重点涵盖 **用户认证** 与 **商家入驻** 流程。系统采用 **六边形架构（Hexagonal Architecture）** 模式，确保业务的高内聚与低耦合。

## 1. 总体架构设计 (System Architecture)

本系统采用 **微服务（Microservices）** 架构，通过 **GraphQL Federation** 构建统一的 GraphQL 数据图（Supergraph）。各服务独立部署、独立存储，通过事件驱动（Event-Driven）机制进行协作。

### 1.1 核心技术栈与优势
*   **接入层 (Gateway)**: **Spring Gateway** 和 **Apollo Router**
    *   **优势**:
    *   **作为统一流量入口，负责请求路由、鉴权、聚合子图（Subgraphs）结果。相比传统 REST API 网关，它能按需查询，减少网络开销（Over-fetching/Under-fetching）。**
    *   **前端对接友好，只需`1`种请求方式`POST`请求同一端点如`/graphql`，发送内容结构一致无需传统 REST API花样百出，后端可通过每个请求具体的字段名进行精细的宽展权限控制**
*   **接口层 (API)**: **Spring Boot + Spring for GraphQL**
    *   **优势**:
        *   **基于官方标准，与 Spring 生态（Security, GraphQL）无缝集成；支持传统编程模型，开发体验流畅。**
        *   **通过GraphQL DateRevolver BatchLoader解决 N+1 问题，确保查询高效**
*   **业务模型层 (Domain)**: **业务内聚**
    *   **优势**:
        *   **极简建模体验**: 由于使用了 GraphQL 特性，**每个模块的模型设计保持极致简单**。服务间仅需引用关联对象的 **ID**（如商家服务仅存 `ownerId`），无需在代码或数据库层面处理复杂的跨服务关联。数据的聚合与拼装完全由 GraphQL 层自动处理，显著降低了开发心智负担与维护成本。
        *   **聚合根（Aggregate Root）** 保证业务操作的原子性。
        *   **领域事件（Domain Events）** 实现微服务间的解耦与最终一致性（如：商家服务 -> 通知服务）。
        *   **Saga 模式**: 处理跨服务的长事务（如：商家入驻涉及账号创建、权限分配、支付签约）。
*   **基础设施层 (Infrastructure)**: **JPA (Hibernate) + Redis**
    *   **优势**: 通过 `Repository` 接口倒置依赖，业务逻辑不依赖具体数据库实现。

### 1.2 系统架构图 (System Context)

```mermaid
graph TD
    User[用户 (Client/Web/App)] -->|GraphQL Query/Mutation| Gateway[Apollo Router (Gateway)]
    
    subgraph "Microservices Cluster"
        Gateway -->|Sub-query| AuthModule[认证服务 (Auth Service)]
        Gateway -->|Sub-query| MemberModule[用户服务 (Member Service)]
        Gateway -->|Sub-query| MerchantModule[商家服务 (Merchant Service)]
        
        AuthModule -.->|Issue Token| Redis[(Redis Cache)]
        MerchantModule -.->|Publish Event| Kafka[Message Broker (Kafka)]
        MemberModule -.->|Consume Event| Kafka
    end
    
    subgraph "Persistence Layer"
        AuthModule --> DB_Auth[(Auth DB)]
        MemberModule --> DB_Member[(Member DB)]
        MerchantModule --> DB_Merchant[(Merchant DB)]
    end
```

---

## 2. 业务流程与技术实现

### 2.1 用户体系设计 (User/Member)

**Member** 服务作为核心用户中心，管理平台所有用户（包含 C 端用户和 B 端商家员工）。

#### 2.1.1 核心模型
*   **Member**: 聚合根，包含基础信息（Email, Phone, Password）。
*   **Identity Provider**: 支持本地密码验证及 OAuth2（微信/其他第三方）绑定。

#### 2.1.2 登录认证流程 (Authentication Flow)
采用 **JWT + Cookie** 模式，结合 Spring Security 实现无状态认证。

1.  **登录请求**: 用户提交凭证（账号密码/验证码）。
2.  **校验**: `Authentication Service` 校验凭证，通过 `RateLimiter` 防止暴力破解。
3.  **颁发令牌**: 生成 JWT (`AccessToken`) 和 `RefreshToken`。
    *   *技术细节*: `AccessToken` 短效，用于 API 调用；`RefreshToken` 长效，存储在 `HttpOnly Cookie` 中，防止 XSS 攻击。
4.  **上下文传递**: 请求经过 Apollo Router 时，Token 被解析并透传给后端子服务，通过 `SecurityContext` 恢复用户身份。

**优势**:
*   **安全性**: `HttpOnly Cookie` 避免了 Token 被前端脚本窃取。
*   **性能**: JWT 自包含用户信息，网关无需频繁查库校验。

---

### 2.2 商家入驻流程设计 (Merchant Onboarding)

**Merchant** 服务独立管理商家（Tenant）生命周期。

#### 2.2.1 商家入驻状态机
入驻是一个长流程，需设计状态机管理：
`APPLIED` (已申请) -> `UNDER_REVIEW` (审核中) -> `APPROVED` (已通过) -> `ACTIVE` (已激活/已缴费)

#### 2.2.2 入驻时序图 (Onboarding Sequence)

```mermaid
sequenceDiagram
    participant U as 用户 (Member)
    participant G as 网关 (Apollo Router)
    participant M as 商家服务 (Merchant Service)
    participant E as 事件总线 (Eventuate/Kafka)
    participant N as 通知服务 (Notification Service)

    Note over U, G: 1. 提交入驻申请
    U->>G: mutation applyForMerchant(input: {name, license...})
    G->>M: ApplyForMerchantCommand
    
    activate M
    M->>M: 校验参数 & 唯一性检查
    M->>M: 创建 Merchant 聚合 (State: APPLIED)
    M->>E: 发布 MerchantAppliedEvent
    M-->>G: 返回申请单 ID
    deactivate M
    G-->>U: 提交成功，等待审核

    Note over M, N: 2. 异步处理
    E->>N: 消费 MerchantAppliedEvent
    N->>N: 发送邮件给管理员 (审核提醒)

    Note over U, G: 3. 管理员审核通过
    U->>G: mutation approveMerchant(id: "123")
    G->>M: ApproveMerchantCommand
    activate M
    M->>M: 更新状态 (State: APPROVED)
    M->>E: 发布 MerchantApprovedEvent
    deactivate M

    Note over E, N: 4. 后续自动化流程 (Saga)
    E->>N: 消费 MerchantApprovedEvent
    N->>U: 发送开通成功通知
    E->>M: 触发初始化 (分配默认权限/资源)
```

#### 2.2.3 关键技术点
1.  **CQRS (命令查询职责分离)**:
    *   **写操作 (Command)**: 如 `applyForMerchant`，只负责校验和状态变更，不返回复杂视图数据，保证高性能。
    *   **读操作 (Query)**: 如查询商家列表，利用 `BatchLoadingOptimizer` 解决 N+1 问题，确保列表查询高效。
2.  **事件驱动 (Event-Driven)**:
    *   **解耦**: 商家服务不需要知道“审核通过后要发邮件”、“要初始化存储空间”。它只负责发布 `MerchantApprovedEvent`。
    *   **扩展性**: 未来如果新增“审核通过后赠送优惠券”功能，只需新增一个监听器，无需修改核心代码。
3.  **六边形架构**:
    *   核心业务逻辑（`Merchant` 实体）不依赖 Spring 或数据库注解，纯净且易于单元测试。
    *   所有外部依赖（数据库、第三方 API）通过接口适配器（Infrastructure）注入。

## 3. 部署与演进策略

本架构设计天然支持 **微服务部署**，同时也兼容 **模块化单体** 模式，以适应不同的基础设施环境。

*   **微服务模式 (Default)**: 各模块（Auth, Member, Merchant）打包为独立的 Docker 容器，云原生天然友好，通过 Kubernetes 进行编排。Gateway作为统一入口，动态路由至各服务实例。
*   **兼容单体模式**: 由于代码层面保持了严格的模块隔离（Module Isolation），所有模块也可以打包在一个 JAR 中运行，仅需调整 Gateway 的路由配置指向同一实例。

---

## 4. 总结
本架构设计严格遵循 **“高内聚、低耦合”** 原则。通过采用微服务架构（Microservices）与事件驱动（Event-Driven）模式，我们不仅能快速实现商家入驻流程，还能确保系统具备支撑未来业务指数级增长的能力。

**核心优势**:
1. **业务清晰**: `Member` (用户) 与 `Merchant` (商家) 职责分离，服务边界明确。
2. **技术先进**: GraphQL Federation + Event Sourcing，保证了灵活性与性能。
3. **可维护性**: 严格的六边形架构，让代码易于测试和维护。
4. **无技术债务**: 基于优秀且全球性庞大基数的顶级完全免费开源框架及中间件，没有技术黑盒内幕供应商锁定等问题，后续版本升级迭代无后顾之忧。
5. **无数据库供应商锁死**: 项目无手动编写的原生SQL，由ORM生成数据库操作SQL的同时保持模型单方面自我简洁性(通常无需考虑1对多多对多复杂关系)，无感切换数据库
6. **开发流程**: 理解需求 -> 设计关联GraphQL Schema -> 业务模型 -> ORM数据库映射： 自动生成常规CRUD操作接口，AI辅助编码或手动实现定制业务逻辑
