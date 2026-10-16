package edu.zjxu.jxucampushub.widget

import edu.zjxu.jxucampushub.R

/**
 * 中 / 大组件的「课程行槽位」view id（由 tools 脚本按布局生成，布局里槽位数见各 XML）。
 * [bg] / [nameOn] 为 0 表示该槽位没有强调底 / 进行中加粗名称（大组件的「接下来」）。
 */
internal class SlotIds(
    val container: Int,
    val course: Int,
    val bg: Int,
    val time: Int,
    val name: Int,
    val nameOn: Int,
    val location: Int,
    val label: Int,
)

internal object CampusWidgetSlotIds {
    val MEDIUM = listOf(
        SlotIds(R.id.widget_row_1, R.id.widget_row_1_course, R.id.widget_row_1_bg, R.id.widget_row_1_time, R.id.widget_row_1_name, R.id.widget_row_1_name_on, R.id.widget_row_1_location, R.id.widget_row_1_label),
        SlotIds(R.id.widget_row_2, R.id.widget_row_2_course, R.id.widget_row_2_bg, R.id.widget_row_2_time, R.id.widget_row_2_name, R.id.widget_row_2_name_on, R.id.widget_row_2_location, R.id.widget_row_2_label),
        SlotIds(R.id.widget_row_3, R.id.widget_row_3_course, R.id.widget_row_3_bg, R.id.widget_row_3_time, R.id.widget_row_3_name, R.id.widget_row_3_name_on, R.id.widget_row_3_location, R.id.widget_row_3_label),
        SlotIds(R.id.widget_row_4, R.id.widget_row_4_course, R.id.widget_row_4_bg, R.id.widget_row_4_time, R.id.widget_row_4_name, R.id.widget_row_4_name_on, R.id.widget_row_4_location, R.id.widget_row_4_label),
        SlotIds(R.id.widget_row_5, R.id.widget_row_5_course, R.id.widget_row_5_bg, R.id.widget_row_5_time, R.id.widget_row_5_name, R.id.widget_row_5_name_on, R.id.widget_row_5_location, R.id.widget_row_5_label),
        SlotIds(R.id.widget_row_6, R.id.widget_row_6_course, R.id.widget_row_6_bg, R.id.widget_row_6_time, R.id.widget_row_6_name, R.id.widget_row_6_name_on, R.id.widget_row_6_location, R.id.widget_row_6_label),
        SlotIds(R.id.widget_row_7, R.id.widget_row_7_course, R.id.widget_row_7_bg, R.id.widget_row_7_time, R.id.widget_row_7_name, R.id.widget_row_7_name_on, R.id.widget_row_7_location, R.id.widget_row_7_label),
        SlotIds(R.id.widget_row_8, R.id.widget_row_8_course, R.id.widget_row_8_bg, R.id.widget_row_8_time, R.id.widget_row_8_name, R.id.widget_row_8_name_on, R.id.widget_row_8_location, R.id.widget_row_8_label),
        SlotIds(R.id.widget_row_9, R.id.widget_row_9_course, R.id.widget_row_9_bg, R.id.widget_row_9_time, R.id.widget_row_9_name, R.id.widget_row_9_name_on, R.id.widget_row_9_location, R.id.widget_row_9_label),
        SlotIds(R.id.widget_row_10, R.id.widget_row_10_course, R.id.widget_row_10_bg, R.id.widget_row_10_time, R.id.widget_row_10_name, R.id.widget_row_10_name_on, R.id.widget_row_10_location, R.id.widget_row_10_label),
    )

    val LARGE_NEXT = listOf(
        SlotIds(R.id.widget_next_1, R.id.widget_next_1_course, 0, R.id.widget_next_1_time, R.id.widget_next_1_name, 0, R.id.widget_next_1_location, R.id.widget_next_1_label),
        SlotIds(R.id.widget_next_2, R.id.widget_next_2_course, 0, R.id.widget_next_2_time, R.id.widget_next_2_name, 0, R.id.widget_next_2_location, R.id.widget_next_2_label),
        SlotIds(R.id.widget_next_3, R.id.widget_next_3_course, 0, R.id.widget_next_3_time, R.id.widget_next_3_name, 0, R.id.widget_next_3_location, R.id.widget_next_3_label),
        SlotIds(R.id.widget_next_4, R.id.widget_next_4_course, 0, R.id.widget_next_4_time, R.id.widget_next_4_name, 0, R.id.widget_next_4_location, R.id.widget_next_4_label),
        SlotIds(R.id.widget_next_5, R.id.widget_next_5_course, 0, R.id.widget_next_5_time, R.id.widget_next_5_name, 0, R.id.widget_next_5_location, R.id.widget_next_5_label),
        SlotIds(R.id.widget_next_6, R.id.widget_next_6_course, 0, R.id.widget_next_6_time, R.id.widget_next_6_name, 0, R.id.widget_next_6_location, R.id.widget_next_6_label),
        SlotIds(R.id.widget_next_7, R.id.widget_next_7_course, 0, R.id.widget_next_7_time, R.id.widget_next_7_name, 0, R.id.widget_next_7_location, R.id.widget_next_7_label),
        SlotIds(R.id.widget_next_8, R.id.widget_next_8_course, 0, R.id.widget_next_8_time, R.id.widget_next_8_name, 0, R.id.widget_next_8_location, R.id.widget_next_8_label),
        SlotIds(R.id.widget_next_9, R.id.widget_next_9_course, 0, R.id.widget_next_9_time, R.id.widget_next_9_name, 0, R.id.widget_next_9_location, R.id.widget_next_9_label),
        SlotIds(R.id.widget_next_10, R.id.widget_next_10_course, 0, R.id.widget_next_10_time, R.id.widget_next_10_name, 0, R.id.widget_next_10_location, R.id.widget_next_10_label),
        SlotIds(R.id.widget_next_11, R.id.widget_next_11_course, 0, R.id.widget_next_11_time, R.id.widget_next_11_name, 0, R.id.widget_next_11_location, R.id.widget_next_11_label),
        SlotIds(R.id.widget_next_12, R.id.widget_next_12_course, 0, R.id.widget_next_12_time, R.id.widget_next_12_name, 0, R.id.widget_next_12_location, R.id.widget_next_12_label),
    )
}
