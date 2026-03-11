import SwiftUI

// MARK: - Group Chat Header
// Extracted from ContentView. Used by ContentView's topBarView.

struct GroupChatHeaderView: View {
    @ObservedObject var vm: ClawMuxViewModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.cAccent)
            Text(vm.activeGroupName ?? "Group Chat")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.cText)
                .lineLimit(1)
            Spacer()
            let dotColor: Color = vm.isConnected ? .cSuccess : vm.isConnecting ? .cCaution : .cDanger
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .padding(6)
                .background(Color.glass, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.glassBorder, lineWidth: 0.5))
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background {
            if #available(iOS 26, *) {
                Color.clear.glassEffect(.regular, in: TopOpenRect()).ignoresSafeArea(edges: .top)
            } else {
                Color.clear.background(.ultraThinMaterial).ignoresSafeArea(edges: .top)
            }
        }
    }
}

// MARK: - Group Chat Scroll Area

struct GroupChatScrollView: View {
    @ObservedObject var vm: ClawMuxViewModel
    @Binding var showCopiedToast: Bool
    @State private var isAtBottom: Bool = true

    var body: some View {
        ZStack {
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 8) {
                            let displayMsgs = vm.groupMessages.filter { !$0.isBareAck }
                            let ackedBySenders: [String: [String]] = vm.groupMessages
                                .filter { $0.isBareAck }
                                .reduce(into: [:]) { dict, ack in
                                    if let pid = ack.parentId { dict[pid, default: []].append(ack.sender) }
                                }
                            ForEach(Array(displayMsgs.enumerated()), id: \.element.id) { idx, msg in
                                VStack(alignment: msg.role == "user" ? .trailing : .leading, spacing: 2) {
                                    groupMessageBubble(msg, isLast: idx == displayMsgs.count - 1)
                                    if let senders = ackedBySenders[msg.id], !senders.isEmpty {
                                        HStack(spacing: 4) {
                                            Text("👍").font(.system(size: 12)).foregroundStyle(Color.cTextTer)
                                            ForEach(senders, id: \.self) { voiceId in
                                                ZStack {
                                                    Circle().fill(voiceColor(voiceId).opacity(0.15))
                                                    Image(systemName: voiceIcon(voiceId))
                                                        .font(.system(size: 7, weight: .semibold))
                                                        .foregroundStyle(voiceColor(voiceId))
                                                }
                                                .frame(width: 18, height: 18)
                                            }
                                        }
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.cCard.opacity(0.6), in: Capsule())
                                    }
                                }
                            }
                            Color.clear.frame(height: 16).id("gc-bottom")
                        }
                        .padding(.horizontal, 12).padding(.top, 64).padding(.bottom, 8)
                    }
                    .contentMargins(.leading, 48, for: .scrollContent)
                    .modifier(ScrollBottomDetector(isAtBottom: $isAtBottom))
                    .onChange(of: vm.groupMessages.count) { _, _ in
                        guard isAtBottom else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo("gc-bottom", anchor: .bottom)
                        }
                    }
                    .onAppear {
                        if let name = vm.activeGroupName { vm.fetchGroupHistory(groupName: name) }
                        proxy.scrollTo("gc-bottom", anchor: .bottom)
                    }

                    if !isAtBottom {
                        Button {
                            var t = Transaction()
                            t.disablesAnimations = true
                            withTransaction(t) { proxy.scrollTo("gc-bottom", anchor: .bottom) }
                            isAtBottom = true
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
            // Empty state
            if vm.groupMessages.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 32, weight: .thin))
                        .foregroundStyle(Color.cTextTer)
                    Text("No messages yet")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.cTextSec)
                    Text("Start the conversation below")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.cTextTer)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func groupMessageBubble(_ msg: GroupChatMessage, isLast: Bool) -> some View {
        let isUser = msg.role == "user" && msg.sender.isEmpty
        let color = isUser ? Color.clear : voiceColor(msg.sender)
        let senderLabel = isUser ? nil : (ALL_VOICES.first { $0.id == msg.sender }?.name ?? msg.sender)

        let shape = UnevenRoundedRectangle(
            topLeadingRadius: isUser ? 18 : 4,
            bottomLeadingRadius: 18,
            bottomTrailingRadius: isUser ? 4 : 18,
            topTrailingRadius: 18,
            style: .continuous)

        HStack(alignment: .bottom, spacing: 0) {
            if isUser { Spacer(minLength: 56) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                if let label = senderLabel {
                    Text(label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 4)
                }
                MarkdownContentView(text: msg.text, foreground: Color.cText,
                                    fontSize: CGFloat(vm.chatFontSize))
                    .padding(.horizontal, isUser ? 12 : 14)
                    .padding(.vertical, 8)
                    .background(shape.fill(isUser ? Color.cAccent.opacity(0.18) : Color.cCard))
                    .overlay(shape.fill(isUser ? Color.clear : color.opacity(0.20)))
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = msg.text
                            withAnimation { showCopiedToast = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation { showCopiedToast = false }
                            }
                        } label: { Label("Copy", systemImage: "doc.on.doc") }
                        if !isUser {
                            Button { vm.sendUserAck(msgId: msg.id) }
                                label: { Label("Acknowledge", systemImage: "hand.thumbsup") }
                        }
                    }
                if isLast {
                    Text(shortTime(Date(timeIntervalSince1970: msg.ts)))
                        .font(.system(size: 9))
                        .foregroundStyle(Color.cTextTer)
                        .padding(.horizontal, 4)
                }
            }
            if !isUser { Spacer(minLength: 56) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}
