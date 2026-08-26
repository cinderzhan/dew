import SwiftUI

struct TodoTab: View {
    @EnvironmentObject var todos: TodoStore
    let skin: Skin

    @State private var draft = ""
    @State private var draftKind: TodoKind = .normal
    @FocusState private var inputFocused: Bool

    var body: some View {
        // 显式容器，理由同 AgentsTab
        VStack(alignment: .leading, spacing: 0) {
            input

            if todos.items.isEmpty {
                EmptyHint(text: L(.emptyTodo), skin: skin)
            } else {
                ForEach(TodoKind.allCases, id: \.self) { kind in
                    let list = todos.items(of: kind)
                    if !list.isEmpty {
                        GroupHeader(title: kind.label, skin: skin,
                                    accent: kind == .high ? skin.signal : nil)
                        ForEach(list) { TodoRow(item: $0, skin: skin) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var input: some View {
        HStack(spacing: 7) {
            TextField(L(.todoPlaceholder), text: $draft)
                .textFieldStyle(.plain)
                .font(Metrics.bodyFont)
                .foregroundStyle(skin.text)
                .focused($inputFocused)
                .onSubmit {
                    todos.add(draft, kind: draftKind)
                    draft = ""
                }

            // 三分类切换。做成一排小字而不是下拉，是为了省掉一次点击。
            HStack(spacing: 3) {
                ForEach(TodoKind.allCases, id: \.self) { k in
                    let on = draftKind == k
                    Button { draftKind = k } label: {
                        Text(shortLabel(k))
                            .font(.system(size: 9.5, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? (k == .high ? skin.signal : skin.text) : skin.faint)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(on ? skin.selection : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(skin.line).frame(height: 0.5) }
    }

    private func shortLabel(_ k: TodoKind) -> String {
        switch k {
        case .high: return L(.todoHighShort)
        case .daily: return L(.todoDailyShort)
        case .normal: return L(.todoNormalShort)
        }
    }
}

struct TodoRow: View {
    @EnvironmentObject var todos: TodoStore
    let item: TodoItem
    let skin: Skin
    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            // 复选框本体 12pt，但可点区域放大到 24pt——12pt 的靶子在快速点击时
            // 十有八九落在外面，这就是「不灵敏」的来源。
            Button { todos.toggle(item) } label: {
                checkbox
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, -4)
            .padding(.leading, -6)

            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(titleFont)
                    .foregroundStyle(skin.text)
                    .lineLimit(1)
                    .focused($editorFocused)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onSubmit(commit)
                    // 失焦也保存。点到别处就丢掉刚打的字，比「回车才算数」更让人恼火。
                    .onChange(of: editorFocused) { _, focused in if !focused { commit() } }
                    .onAppear { editorFocused = true }
            } else {
                Text(item.title)
                    .font(titleFont)
                    .foregroundStyle(item.done ? skin.faint : skin.text)
                    .strikethrough(item.done, color: skin.faint)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    // 点文字也能勾选。待办类产品的惯例，也把有效靶面扩到整行。
                    //
                    // 刻意**不做**双击进编辑：SwiftUI 一旦挂上 count: 2 的手势，
                    // 单击就得等双击判定窗口过去才触发，勾选会明显变钝——
                    // 而勾选是这个 tab 里最高频的动作。编辑走 hover 出来的铅笔。
                    .onTapGesture { todos.toggle(item) }
            }

            if hovering && !editing {
                HStack(spacing: 0) {
                    Button(action: beginEditing) {
                        Image(systemName: "pencil")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(skin.faint)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button { todos.remove(item) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(skin.faint)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, -3)
                .padding(.trailing, -4)
            }
        }
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, Metrics.rowVPad)
        .background(hovering || editing ? skin.selection : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L(.edit), action: beginEditing)
            ForEach(TodoKind.allCases, id: \.self) { k in
                if k != item.kind {
                    Button(L(.moveTo, k.label)) { todos.move(item, to: k) }
                }
            }
            Divider()
            Button(L(.delete), role: .destructive) { todos.remove(item) }
        }
    }

    private var titleFont: Font {
        item.kind == .high && !item.done ? .system(size: 12.5, weight: .semibold) : Metrics.bodyFont
    }

    private func beginEditing() {
        draft = item.title
        editing = true
    }

    /// 保存并退出编辑。空标题按「没改」处理，见 TodoStore.rename。
    private func commit() {
        guard editing else { return }
        editing = false
        todos.rename(item, to: draft)
    }

    private var checkbox: some View {
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(item.done ? .clear : skin.faint, lineWidth: 1.2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(item.done ? skin.dim : .clear)
            )
            .frame(width: 12, height: 12)
            .overlay {
                if item.done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(skin.tint.opacity(1))
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
    }
}
