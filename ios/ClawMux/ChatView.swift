import SwiftUI

// MARK: - Chat Scroll Area View
// Contains chat scroll area, message grouping, bubbles, and thinking bubble.

struct ChatScrollAreaView: View {
    @ObservedObject var vm: ClawMuxViewModel
    @Binding var isAtBottom: Bool
    @Binding var isLoadingOlder: Bool
    @Binding var thinkingExpanded: Bool
    @Binding var expandedAgentMsgIds: Set<UUID>
    @Binding var isPulsing: Bool
    @Binding var showCopiedToast: Bool
    @State private var topAnchorId: String? = nil   // first message ID captured before older-message load

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        if isLoadingOlder {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .accessibilityIdentifier("ChatLoadingOlder")
                        }
                        ForEach(messageGroups) { group in
                            messageGroupView(group)
                                .id(group.id)
                                .transition(.opacity.animation(.easeIn(duration: 0.15)))
                        }
                        if vm.activeSession?.isThinking == true {
                            thinkingBubble.id("thinking")
                                .transition(.opacity.animation(.easeOut(duration: 0.18)))
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.leading, 60).padding(.trailing, 12)
                    .padding(.top, 64).padding(.bottom, 16)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("ChatScrollView")
                .modifier(ScrollBottomDetector(isAtBottom: $isAtBottom))
                .modifier(ScrollTopDetector(
                    isLoadingOlder: $isLoadingOlder,
                    hasOlderMessages: vm.activeSession?.hasOlderMessages == true,
                    sessionId: vm.activeSessionId,
                    load: { sid, completion in vm.loadOlderMessages(sessionId: sid, completion: completion) }
                ))
                .onChange(of: isLoadingOlder) { _, loading in
                    if loading {
                        // Capture the first visible message before older messages are prepended
                        topAnchorId = messageGroups.first?.id
                    } else {
                        topAnchorId = nil
                    }
                }
                .onChange(of: vm.activeMessages.count) { _, _ in
                    if isLoadingOlder, let aid = topAnchorId {
                        // Older messages were prepended — scroll to what was the top message
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) { proxy.scrollTo(aid, anchor: .top) }
                        return
                    }
                    guard !isLoadingOlder else { return }
                    scrollBottom(proxy)
                }
                .onChange(of: vm.activeSession?.isThinking) { _, thinking in
                    if thinking != true { thinkingExpanded = false }
                    scrollBottom(proxy)
                }
                .onChange(of: vm.activeSession?.activity) { _, _ in scrollBottom(proxy) }
                .onChange(of: vm.activeSessionId) { _, _ in
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { proxy.scrollTo("bottom", anchor: .bottom) }
                    isAtBottom = true
                }

                if !isAtBottom {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.cText)
                            .frame(width: 32, height: 32)
                            .background {
                                if #available(iOS 26, *) {
                                    Color.clear.glassEffect(.regular, in: .circle)
                                } else {
                                    Color.canvas2.opacity(0.90).background(.ultraThinMaterial, in: Circle())
                                }
                            }
                            .overlay(Circle().strokeBorder(Color.glassBorder, lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 2)
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottomTrailing)))
                    .animation(.spring(response: 0.25), value: isAtBottom)
                }
            }
        }
    }

    private func scrollBottom(_ proxy: ScrollViewProxy) {
        guard isAtBottom else { return }
        withAnimation(.spring(response: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    // MARK: - Message Grouping

    private struct MessageGroup: Identifiable {
        let role: String
        let messages: [ChatMessage]
        var id: String { role + (messages.first?.msgId ?? messages.first?.id.uuidString ?? "") }
    }

    private var messageGroups: [MessageGroup] {
        let filtered = vm.activeMessages.filter { msg in
            if msg.isBareAck { return false }
            if msg.role == "agent" { return vm.showAgentMessages }
            if msg.role == "activity" { return vm.verboseMode }
            return true
        }
        var groups: [MessageGroup] = []
        var cur: String? = nil
        var batch: [ChatMessage] = []
        for msg in filtered {
            if msg.role == cur {
                batch.append(msg)
            } else {
                if !batch.isEmpty { groups.append(MessageGroup(role: cur!, messages: batch)) }
                cur = msg.role; batch = [msg]
            }
        }
        if !batch.isEmpty { groups.append(MessageGroup(role: cur!, messages: batch)) }
        return groups
    }

    private func messageGroupView(_ group: MessageGroup) -> some View {
        let color = vm.activeSession.map { voiceColor($0.voice) } ?? Color.cTextSec
        let ackedIds = Set(vm.activeMessages.filter { $0.isBareAck }.compactMap { $0.parentId })
        return VStack(alignment: group.role == "user" ? .trailing : .leading, spacing: 3) {
            ForEach(Array(group.messages.enumerated()), id: \.element.id) { idx, msg in
                VStack(alignment: group.role == "user" ? .trailing : .leading, spacing: 2) {
                    let bubble = chatBubble(msg,
                        isFirst: idx == 0,
                        isLast:  idx == group.messages.count - 1,
                        role:    group.role)
                    if group.role == "user" {
                        bubble
                            .padding(.leading, 48)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        bubble
                    }
                    if let mid = msg.msgId, ackedIds.contains(mid) {
                        Text("👍").font(.system(size: 14)).padding(.horizontal, 4)
                    }
                }
            }
        }
    }

    private func chatBubble(_ msg: ChatMessage, isFirst: Bool, isLast: Bool, role: String) -> some View {
        let color     = vm.activeSession.map { voiceColor($0.voice) } ?? Color.cTextSec
        let isPlaying = vm.ttsPlayingMessageId == msg.id

        let agentMsgPattern = /^\[Agent msg (from|to) ([^\]]+)\] (.*)/
        let isExpanded = expandedAgentMsgIds.contains(msg.id)
        if (role == "agent" || role == "system"),
           let m = msg.text.firstMatch(of: agentMsgPattern) {
            let direction = String(m.output.1)
            let agentName = String(m.output.2)
            let content   = String(m.output.3)
            let arrow     = direction == "from" ? "←" : "→"
            let agentColor = voiceColor(voiceIdByName(agentName))
            return AnyView(
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(arrow) \(agentName)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(agentColor)
                    if isExpanded {
                        Text(content)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.cTextSec)
                            .padding(.top, 3)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10).padding(.vertical, 4)
                .overlay(alignment: .leading) {
                    agentColor.opacity(0.6).frame(width: 2)
                }
                .padding(.leading, 2)
                .opacity(isExpanded ? 1.0 : 0.7)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if isExpanded { expandedAgentMsgIds.remove(msg.id) }
                        else          { expandedAgentMsgIds.insert(msg.id) }
                    }
                }
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = msg.text
                        withAnimation { showCopiedToast = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { showCopiedToast = false }
                        }
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
            )
        }

        let groupMsgPattern = /^\[Group msg to ([^\]]+)\] ([\s\S]*)/
        if (role == "agent" || role == "system"),
           let gm = msg.text.firstMatch(of: groupMsgPattern) {
            let groupName  = String(gm.output.1)
            let content    = String(gm.output.2)
            let groupColor = Color(hex: 0x7c9ef0)
            return AnyView(
                VStack(alignment: .leading, spacing: 0) {
                    Text("⊕ \(groupName)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(groupColor)
                    if isExpanded {
                        Text(content)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.cTextSec)
                            .padding(.top, 3)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10).padding(.vertical, 4)
                .overlay(alignment: .leading) {
                    groupColor.opacity(0.6).frame(width: 2)
                }
                .padding(.leading, 2)
                .opacity(isExpanded ? 1.0 : 0.7)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if isExpanded { expandedAgentMsgIds.remove(msg.id) }
                        else          { expandedAgentMsgIds.insert(msg.id) }
                    }
                }
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = msg.text
                        withAnimation { showCopiedToast = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { showCopiedToast = false }
                        }
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
            )
        }

        if role == "agent" {
            return AnyView(
                Text(msg.text)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.cTextSec.opacity(0.65))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 3)
            )
        }

        let single = isFirst && isLast
        let tl: CGFloat = (role == "assistant" && !isFirst)  ? 8 : 16
        let bl: CGFloat = role == "assistant" ? (isLast ? 5 : single ? 16 : 8) : 16
        let tr: CGFloat = (role == "user"      && !isFirst)  ? 8 : 16
        let br: CGFloat = role == "user"      ? (isLast ? 5 : single ? 16 : 8) : 16

        let userBubbleColor = Color(hex: 0x2563EB)
        let bubbleBg: AnyShapeStyle = role == "user"
            ? AnyShapeStyle(userBubbleColor)
            : role == "assistant"
                ? AnyShapeStyle(color.opacity(isPlaying ? 0.22 : 0.20))
                : AnyShapeStyle(Color.clear)

        return AnyView(HStack(alignment: .bottom, spacing: 0) {
            if role == "system" { Spacer() }

            VStack(alignment: role == "user" ? .trailing : .leading, spacing: 3) {
                Group {
                    if role == "assistant" {
                        MarkdownContentView(text: msg.text, foreground: Color.cText, fontSize: CGFloat(vm.chatFontSize),
                                            baseURL: vm.httpBaseURL()?.absoluteString ?? "")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if role == "user" {
                        Text(msg.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: CGFloat(vm.chatFontSize)))
                            .lineSpacing(4)
                            .tracking(CGFloat(vm.chatFontSize) * -0.01)
                            .foregroundStyle(Color.white)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(msg.text)
                            .font(.caption)
                            .foregroundStyle(Color.cTextTer)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(.horizontal, role == "system" ? 0 : 15)
                .padding(.vertical, role == "system" ? 4 : 10)
                .background {
                    UnevenRoundedRectangle(
                        topLeadingRadius: tl, bottomLeadingRadius: bl,
                        bottomTrailingRadius: br, topTrailingRadius: tr,
                        style: .continuous)
                    .fill(bubbleBg)
                    .shadow(color: role == "assistant" ? Color.black.opacity(0.3) : Color.clear, radius: 3, x: 0, y: 1)
                }
                .overlay {
                    if role == "assistant" {
                        UnevenRoundedRectangle(
                            topLeadingRadius: tl, bottomLeadingRadius: bl,
                            bottomTrailingRadius: br, topTrailingRadius: tr,
                            style: .continuous)
                        .strokeBorder(
                            isPlaying ? color.opacity(isPulsing ? 0.7 : 0.2) : Color.clear,
                            lineWidth: 1)
                        .animation(
                            isPlaying ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : .default,
                            value: isPulsing)
                    }
                }
                .contextMenu {
                    if role == "assistant" {
                        Button {
                            vm.playMessageTTS(
                                messageId: msg.id,
                                text: msg.text,
                                voice: vm.activeSession?.voice)
                        } label: {
                            Label(isPlaying ? "Stop Playing" : "Play",
                                  systemImage: isPlaying ? "stop.fill" : "play.fill")
                        }
                        if let mid = msg.msgId {
                            Button {
                                vm.sendUserAck(msgId: mid)
                                withAnimation { showCopiedToast = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    withAnimation { showCopiedToast = false }
                                }
                            } label: {
                                Label("Acknowledge", systemImage: "hand.thumbsup")
                            }
                        }
                    }
                    Button {
                        UIPasteboard.general.string = msg.text
                        withAnimation { showCopiedToast = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { showCopiedToast = false }
                        }
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }

                if role != "system" && isLast {
                    Text(shortTime(msg.timestamp))
                        .font(.system(size: 9))
                        .foregroundStyle(Color.cTextTer)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: role == "user" ? .trailing : .leading)
                }
            }

            if role == "assistant" { Spacer(minLength: 56) }
            if role == "system"   { Spacer() }
        })
    }

    // MARK: - Thinking Bubble

    var thinkingBubble: some View {
        let session  = vm.activeSession
        let hasDetail = session.map { !$0.activity.isEmpty || !$0.toolName.isEmpty } ?? false

        return HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    guard hasDetail else { return }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        thinkingExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        TimelineView(.animation) { tl in
                            HStack(spacing: 5) {
                                ForEach(0..<3, id: \.self) { i in
                                    let t = tl.date.timeIntervalSinceReferenceDate
                                    let period = 1.3
                                    let phase = (t + Double(i) * 0.18).truncatingRemainder(dividingBy: period) / period
                                    let (yOff, opacity): (Double, Double) = {
                                        if phase < 0.3 {
                                            let p = phase / 0.3
                                            let e = p * p * (3 - 2 * p)
                                            return (-5.0 * e, 0.45 + 0.55 * e)
                                        } else if phase < 0.6 {
                                            let p = (phase - 0.3) / 0.3
                                            let e = p * p * (3 - 2 * p)
                                            return (-5.0 * (1 - e), 1.0 - 0.55 * e)
                                        } else {
                                            return (0, 0.45)
                                        }
                                    }()
                                    Circle()
                                        .fill(Color.cTextTer.opacity(opacity))
                                        .frame(width: 7, height: 7)
                                        .offset(y: yOff)
                                }
                            }
                        }
                        if hasDetail, let s = session {
                            let summary = s.activity.isEmpty ? s.toolName : s.activity
                            Text(summary)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.cTextTer)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        if hasDetail {
                            Image(systemName: thinkingExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.cTextTer)
                        }
                    }
                }
                .buttonStyle(.plain)

                if thinkingExpanded, let s = session, hasDetail {
                    VStack(alignment: .leading, spacing: 3) {
                        if !s.activity.isEmpty {
                            Text(s.activity)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.cTextSec)
                                .lineLimit(2).truncationMode(.tail)
                        }
                        if !s.toolName.isEmpty {
                            Text(s.toolName)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.cTextTer)
                                .lineLimit(2).truncationMode(.middle)
                        }
                    }
                    .padding(.top, 7)
                    .overlay(alignment: .top) {
                        Divider().foregroundStyle(Color.cBorder)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.cCard,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 18, bottomLeadingRadius: 4,
                    bottomTrailingRadius: 18, topTrailingRadius: 18,
                    style: .continuous))
            .onAppear { isPulsing = true }

            Spacer(minLength: 40)
        }
    }
}
