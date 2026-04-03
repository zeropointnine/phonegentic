import 'package:flutter/material.dart';

import '../theme_provider.dart';

class EmojiPickerWidget extends StatefulWidget {
  final ValueChanged<String> onSelected;

  const EmojiPickerWidget({Key? key, required this.onSelected})
      : super(key: key);

  @override
  State<EmojiPickerWidget> createState() => _EmojiPickerWidgetState();
}

class _EmojiPickerWidgetState extends State<EmojiPickerWidget> {
  int _categoryIndex = 0;
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activeEmojis = _searchCtrl.text.isEmpty
        ? _categories[_categoryIndex].emojis
        : _allEmojis
            .where((e) => e.toLowerCase().contains(_searchCtrl.text.toLowerCase()))
            .toList();

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(
          top: BorderSide(color: AppColors.border.withOpacity(0.4), width: 0.5),
        ),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 30,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              itemCount: _categories.length,
              itemBuilder: (_, i) {
                final selected = i == _categoryIndex;
                return GestureDetector(
                  onTap: () => setState(() {
                    _categoryIndex = i;
                    _searchCtrl.clear();
                  }),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 1),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: selected
                          ? AppColors.accent.withOpacity(0.15)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      _categories[i].icon,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                );
              },
            ),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 10,
                mainAxisSpacing: 0,
                crossAxisSpacing: 0,
                childAspectRatio: 1,
              ),
              itemCount: activeEmojis.length,
              itemBuilder: (_, i) {
                return GestureDetector(
                  onTap: () => widget.onSelected(activeEmojis[i]),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        activeEmojis[i],
                        style: const TextStyle(fontSize: 20),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static List<String> get _allEmojis =>
      _categories.expand((c) => c.emojis).toList();
}

class _EmojiCategory {
  final String icon;
  final String name;
  final List<String> emojis;
  const _EmojiCategory(this.icon, this.name, this.emojis);
}

const _categories = [
  _EmojiCategory('😀', 'Smileys', [
    '😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂', '🙂', '🙃',
    '😉', '😊', '😇', '🥰', '😍', '🤩', '😘', '😗', '☺️', '😚',
    '😋', '😛', '😜', '🤪', '😝', '🤑', '🤗', '🤭', '🤫', '🤔',
    '🤐', '🤨', '😐', '😑', '😶', '😏', '😒', '🙄', '😬', '😮‍💨',
    '🤥', '😌', '😔', '😪', '🤤', '😴', '😷', '🤒', '🤕', '🤢',
    '🤮', '🥵', '🥶', '🥴', '😵', '🤯', '🤠', '🥳', '🥸', '😎',
  ]),
  _EmojiCategory('👋', 'Gestures', [
    '👋', '🤚', '🖐️', '✋', '🖖', '👌', '🤌', '🤏', '✌️', '🤞',
    '🤟', '🤘', '🤙', '👈', '👉', '👆', '🖕', '👇', '☝️', '👍',
    '👎', '✊', '👊', '🤛', '🤜', '👏', '🙌', '👐', '🤲', '🙏',
    '💪', '🦾', '🫶', '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤',
  ]),
  _EmojiCategory('🐶', 'Animals', [
    '🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼', '🐨', '🐯',
    '🦁', '🐮', '🐷', '🐸', '🐵', '🐔', '🐧', '🐦', '🦆', '🦅',
    '🦉', '🦇', '🐺', '🐗', '🐴', '🦄', '🐝', '🐛', '🦋', '🐌',
  ]),
  _EmojiCategory('🍎', 'Food', [
    '🍎', '🍐', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓', '🫐', '🍈',
    '🍒', '🍑', '🥭', '🍍', '🥥', '🥝', '🍅', '🍆', '🥑', '🫛',
    '🥦', '🥬', '🥒', '🌶️', '🫑', '🌽', '🥕', '🫒', '🧄', '🧅',
    '🍔', '🍟', '🍕', '🌭', '🥪', '🌮', '🌯', '🧇', '🥞', '☕',
  ]),
  _EmojiCategory('⚡', 'Objects', [
    '⚡', '🔥', '💧', '🌟', '✨', '🎉', '🎊', '🎈', '🎁', '🏆',
    '🥇', '🎯', '💡', '🔑', '🔒', '📱', '💻', '🖥️', '📞', '📧',
    '📝', '📌', '📎', '✏️', '📋', '📁', '🗑️', '🔔', '🔕', '💰',
    '✅', '❌', '⭕', '❗', '❓', '💯', '🔴', '🟢', '🔵', '⚪',
  ]),
];
